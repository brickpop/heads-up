import HeadsUpCore
import SwiftUI

/// The Chat tab's conversation: the 40 pt toolbar, then the messages, newest at the bottom.
/// Its height follows the messages between 160 and 440 pt.
///
/// It follows a growing reply while the view is at the bottom, or within 40 pt of it, and
/// stops following once the user scrolls up; scrolling back down, or a new message, starts
/// following again (Chat spec).
struct ConversationView: View {
    let model: AppModel

    @State private var contentHeight = HUDStyle.Chat.minHeight
    /// Where the bottom of the messages is, measured from the top of the visible area.
    @State private var bottomOffset: CGFloat = 0
    @State private var following = true

    private static let bottomID = "conversation.bottom"
    private static let space = "conversation"

    var body: some View {
        let chat = model.chat
        let screen = chat.screen
        let height = min(max(contentHeight, HUDStyle.Chat.minHeight), HUDStyle.Chat.maxHeight)
        VStack(spacing: 0) {
            ChatToolbar(toolbar: screen.toolbar, chat: chat, hud: model.hud)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: HUDStyle.Chat.messageGap) {
                        ForEach(screen.messages) { message in
                            MessageView(model: model, message: message)
                                .id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.frame(in: .named(Self.space)).minY
                            } action: { offset in
                                // When the end moves by exactly as much as the content grew, the
                                // reply grew; any other move is the user scrolling, which decides
                                // whether to keep following.
                                let grew = contentHeight - contentHeightAtOffset
                                if abs((offset - bottomOffset) - grew) > 1 {
                                    following = offset - height <= HUDStyle.Chat.followSlack
                                }
                                bottomOffset = offset
                                contentHeightAtOffset = contentHeight
                            }
                    }
                    .padding(.top, HUDStyle.Chat.topPadding)
                    .padding(.horizontal, HUDStyle.Chat.sidePadding)
                    .padding(.bottom, HUDStyle.Chat.bottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight = $0
                    }
                }
                .coordinateSpace(name: Self.space)
                .defaultScrollAnchor(.bottom)
                .onChange(of: screen.messages.count) {
                    following = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: screen.messages) {
                    if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            .frame(height: height)
        }
    }

    /// The content's height when `bottomOffset` was last measured.
    @State private var contentHeightAtOffset: CGFloat = 0
}

/// The chat toolbar: whether the chat is kept, Pinned · N, Pin, Stop while the model answers,
/// and New.
private struct ChatToolbar: View {
    let toolbar: ChatScreen.Toolbar
    let chat: ChatStore
    let hud: HUDStore

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            if let problem = toolbar.problem {
                // Saving the pinned copy failed: said here, never as a toast.
                Image(systemName: Symbols.failedDot)
                    .foregroundStyle(HUDStyle.Colors.alert)
                    .accessibilityHidden(true)
                Text(problem.text)
                    .foregroundStyle(HUDStyle.Colors.alert)
                    .lineLimit(1)
                    // The line is cut to fit the toolbar, so the whole text is in the tooltip.
                    .help(problem.text)
                    .onAppear { AccessibilityNotification.Announcement(problem.text).post() }
                Button(problem.tryAgain) { chat.retryPin() }
                    .buttonStyle(.borderless)
            } else {
                // Whether this chat is kept: a gray dot when it isn't, an accent one when pinned.
                Circle()
                    .fill(toolbar.saved == .pinned ? Color.accentColor : HUDStyle.Colors.track)
                    .frame(width: HUDStyle.Pinned.saveDotSize, height: HUDStyle.Pinned.saveDotSize)
                    .accessibilityHidden(true)
                Text(toolbar.saveLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                hud.togglePinnedList()
            } label: {
                Label(toolbar.pinnedList, systemImage: Symbols.list)
            }
            .buttonStyle(.borderless)
            PinToggle(pin: toolbar.pin) { chat.togglePin() }
            if let stop = toolbar.stop {
                Button {
                    chat.stop()
                } label: {
                    Label(stop, systemImage: Glyph.stop.symbolName)
                }
                .buttonStyle(.outline)
            }
            Button {
                chat.newChat()
            } label: {
                Label(toolbar.new, systemImage: Glyph.plus.symbolName)
            }
            .buttonStyle(.outline)
            .help(toolbar.newHelp)
        }
        .controlSize(.small)
        .font(.system(size: HUDStyle.Footer.fontSize))
        .padding(.horizontal, HUDStyle.Chat.toolbarPadding)
        .frame(height: HUDStyle.Chat.toolbarHeight)
    }
}

private struct MessageView: View {
    let model: AppModel
    let message: MessageScreen

    var body: some View {
        switch message {
        case .user(let id, let text, let images, let label):
            VStack(alignment: .trailing, spacing: HUDStyle.Attachments.gap) {
                if !images.isEmpty {
                    BubbleImages(thumbs: images)
                }
                // A message may be images only.
                if !text.isEmpty {
                    UserBubble(text: text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .contextMenu { CopyMenu(chat: model.chat, id: id) }
        case .assistant(let reply):
            AssistantMessageView(chat: model.chat, reply: reply)
        case .problem(let row):
            ProblemRowView(model: model, row: row)
        case .linkAsk(let ask):
            LinkAskView(chat: model.chat, ask: ask)
        }
    }
}

/// Copy · Copy as Markdown, on a message.
private struct CopyMenu: View {
    let chat: ChatStore
    let id: ChatMessage.ID

    var body: some View {
        Button(Strings.Chat.copy) { chat.copyMessage(id, asMarkdown: false) }
        Button(Strings.Chat.copyAsMarkdown) { chat.copyMessage(id, asMarkdown: true) }
    }
}

/// The user's message: a right-aligned accent bubble, white text, at most 78 % of the width.
private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Text(text)
                .font(.system(size: HUDStyle.Chat.bodySize))
                .lineSpacing(
                    HUDStyle.lineSpacing(size: HUDStyle.Chat.bodySize, lineHeight: HUDStyle.Chat.bubbleLineHeight)
                )
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.vertical, HUDStyle.Chat.bubbleVerticalPadding)
                .padding(.horizontal, HUDStyle.Chat.bubbleHorizontalPadding)
                .background(
                    Color.accentColor,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: HUDStyle.Chat.bubbleRadius,
                        bottomLeadingRadius: HUDStyle.Chat.bubbleRadius,
                        bottomTrailingRadius: HUDStyle.Chat.bubbleTailRadius,
                        topTrailingRadius: HUDStyle.Chat.bubbleRadius)
                )
                .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in
                    width * HUDStyle.Chat.userMaxWidth
                }
        }
    }
}

/// The model's reply: "Thinking with …" with a pulsing dot until the first words, then its
/// blocks, then "Stopped" if the user stopped it. VoiceOver hears when it starts and ends,
/// never each word.
private struct AssistantMessageView: View {
    let chat: ChatStore
    let reply: AssistantScreen

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Chat.blockGap) {
            if let thinking = reply.thinking {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    ThinkingDot()
                    Text(thinking)
                        .font(.system(size: HUDStyle.Settings.labelSize))
                        .foregroundStyle(.secondary)
                }
            }
            MarkdownBlocksView(blocks: reply.blocks, chat: chat)
                .textSelection(.enabled)
            if let stopped = reply.stopped {
                Text(stopped)
                    .font(.system(size: HUDStyle.Footer.fontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
            width * HUDStyle.Chat.assistantMaxWidth
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(reply.accessibilityLabel)
        .contextMenu { CopyMenu(chat: chat, id: reply.id) }
        .onChange(of: reply.isStreaming) { _, streaming in
            let ended = reply.stopped == nil ? reply.endedAnnouncement : reply.stoppedAnnouncement
            AccessibilityNotification.Announcement(streaming ? reply.startedAnnouncement : ended).post()
        }
    }
}

/// The accent dot that pulses while the model thinks: 1.2 s, opacity .35 → 1, scale .85 → 1.
/// Still with Reduce Motion.
private struct ThinkingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: HUDStyle.Chat.thinkingDotSize, height: HUDStyle.Chat.thinkingDotSize)
            .opacity(reduceMotion || bright ? 1 : 0.35)
            .scaleEffect(reduceMotion || bright ? 1 : 0.85)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bright = true }
            }
            .accessibilityHidden(true)
    }
}

/// An error, a notice, or the step limit, where the reply would be: an icon chip, the title,
/// the explanation, Details, and the buttons that recover. Buttons wait out the F6 guard.
private struct ProblemRowView: View {
    let model: AppModel
    let row: ProblemRow

    var body: some View {
        HStack(alignment: .top, spacing: HUDStyle.Services.rowGap) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: HUDStyle.Chat.rowChipSize, height: HUDStyle.Chat.rowChipSize)
                .background(HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius + 2))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                if let text = row.text {
                    Text(text)
                        .font(.system(size: HUDStyle.Footer.fontSize))
                        .foregroundStyle(.secondary)
                }
                if let record = row.record {
                    Text(record)
                        .font(.system(size: HUDStyle.Footer.fontSize))
                        .foregroundStyle(.secondary)
                }
                if let details = row.details {
                    DisclosureGroup(Strings.Chat.details) {
                        Text(details)
                            .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                            .lineLimit(HUDStyle.Chat.detailsLineLimit)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: HUDStyle.Footer.fontSize))
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: HUDStyle.Footer.keyGap) {
                ArmedTimeline(armedAt: row.armedAt) { isArmed in
                    ForEach(Array(row.buttons.enumerated()), id: \.offset) { _, button in
                        RowButtonView(button: button, isArmed: isArmed) { _ = model.recover(row.id, button.action) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(row.title).post() }
    }

    private var icon: String {
        switch row.icon {
        case .warn: Symbols.warning
        case .danger: Symbols.failedDot
        case .info: Symbols.info
        }
    }

    private var iconColor: Color {
        switch row.icon {
        case .warn: HUDStyle.Colors.warn
        case .danger: HUDStyle.Colors.alert
        case .info: .secondary
        }
    }
}

/// A problem row's button: primary or secondary, 26 pt, never the default. At half opacity
/// while the F6 guard holds (the intent ignores early clicks itself). A button that waits,
/// such as Try again after a rate limit, turns on by itself at `enabledAt`.
private struct RowButtonView: View {
    let button: RowButton
    let isArmed: Bool
    let press: @MainActor () -> Void

    var body: some View {
        TimelineView(.explicit(button.enabledAt.map { [$0] } ?? [])) { context in
            let control = Button(button.title, action: press)
                .controlSize(.small)
                .disabled(button.enabledAt.map { context.date < $0 } ?? false)
                .opacity(isArmed ? 1 : HUDStyle.Chat.unarmedOpacity)
            if button.isPrimary {
                control.buttonStyle(.borderedProminent)
            } else {
                control.buttonStyle(.bordered)
            }
        }
    }
}

/// "Open this link?" with the full address in mono, selectable, and Cancel, Copy and Open,
/// none of them the default. The buttons wait out the F6 guard.
private struct LinkAskView: View {
    let chat: ChatStore
    let ask: LinkAsk

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            Text(ask.question)
                .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
            Text(ask.url)
                .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HUDStyle.Footer.keyGap * 2)
                .background(
                    HUDStyle.Colors.codeBackground, in: RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius + 2)
                )
            ArmedTimeline(armedAt: ask.armedAt) { isArmed in
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    Spacer()
                    Button(ask.cancel) { _ = chat.confirmLink(.cancel) }
                        .buttonStyle(.borderless)
                    Button(ask.copy) { _ = chat.confirmLink(.copy) }
                        .buttonStyle(.bordered)
                    Button(ask.open) { _ = chat.confirmLink(.open) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
                .opacity(isArmed ? 1 : HUDStyle.Chat.unarmedOpacity)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(ask.question).post() }
    }
}

/// Draws its content with `isArmed`: false until `armedAt`, true from then on, redrawing once
/// at that moment (F6). With no `armedAt` (the HUD isn't key) the buttons stay dim. The core's
/// intents ignore early presses whatever this shows.
private struct ArmedTimeline<Content: View>: View {
    let armedAt: Date?
    @ViewBuilder let content: (_ isArmed: Bool) -> Content

    var body: some View {
        TimelineView(.explicit(armedAt.map { [$0] } ?? [])) { context in
            content(armedAt.map { context.date >= $0 } ?? false)
        }
    }
}

/// Pin / Pinned: an outline "Pin" while off, an accent "Pinned" while on (⌘P).
private struct PinToggle: View {
    let pin: ChatScreen.Toolbar.Pin
    let toggle: @MainActor () -> Void

    var body: some View {
        if pin.isOn {
            Button(action: toggle) {
                Label(pin.title, systemImage: Glyph.pin.symbolName)
            }
            .buttonStyle(.borderedProminent)
            .help(pin.help)
            .accessibilityAddTraits(.isSelected)
        } else {
            Button(action: toggle) {
                Label(pin.title, systemImage: Glyph.pin.symbolName)
            }
            .buttonStyle(.outline)
            .help(pin.help)
        }
    }
}
