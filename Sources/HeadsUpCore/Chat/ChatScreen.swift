import Foundation

/// The conversation, ready to draw (contract, slice 8; Nick's msg-628).
public struct ChatScreen: Equatable, Sendable {
    public let toolbar: Toolbar
    public let messages: [MessageScreen]

    public struct Toolbar: Equatable, Sendable {
        /// "New": `chat.newChat()`, also ⌘N.
        public let new: String
        /// "New chat (⌘N)"
        public let newHelp: String
        /// "Stop", while a reply comes: `chat.stop()`, also ⌘.
        public let stop: String?
    }
}

public enum MessageScreen: Equatable, Sendable, Identifiable {
    case user(id: String, text: String, accessibilityLabel: String)
    case assistant(AssistantScreen)
    case problem(ProblemRow)
    /// "Open this link?", after the message holding the link.
    case linkAsk(LinkAsk)

    public var id: String {
        switch self {
        case .user(let id, _, _): id
        case .assistant(let reply): reply.id
        case .problem(let row): row.id
        case .linkAsk(let ask): ask.id
        }
    }
}

/// A reply from the model.
public struct AssistantScreen: Equatable, Sendable, Identifiable {
    public let id: String
    public let blocks: [BlockScreen]
    /// "Thinking with GPT-4o mini…", before the first words.
    public let thinking: String?
    /// "Stopped", after ⌘. or Stop.
    public let stopped: String?
    public let isStreaming: Bool
    public let accessibilityLabel: String
    /// For VoiceOver to announce when `isStreaming` turns on, and when it turns off; "Reply
    /// stopped" instead of the second after Stop.
    public let startedAnnouncement: String
    public let endedAnnouncement: String
    public let stoppedAnnouncement: String
}

/// An inline row: an error with its recovery, the no-model notice, or the step limit.
public struct ProblemRow: Equatable, Sendable, Identifiable {
    public enum Icon: Equatable, Sendable {
        case warn, danger, info
    }

    public let id: String
    public let icon: Icon
    public let title: String
    public let text: String?
    /// The Details disclosure, mono, secrets masked.
    public let details: String?
    /// Each calls `AppModel.recover(id, action)`.
    public let buttons: [RowButton]
    /// What stays once acted on: "Stopped after 8 tool calls · Continued".
    public let record: String?
    /// Its buttons take input now (`ActionGuard`: while the HUD is key, 600 ms after the row
    /// appeared and after the HUD became key). The intent checks this again itself.
    public let isArmed: Bool
    /// When they start taking input, to redraw at; nil while the HUD isn't key.
    public let armedAt: Date?
}

public struct RowButton: Equatable, Sendable {
    public let action: ProblemAction
    public let title: String
    public let isPrimary: Bool
    /// Enabled from this date on; nil is now. A rate limit's Try again waits.
    public let enabledAt: Date?
}

/// What a problem row's button does, through `AppModel.recover(_:_:)`.
public enum ProblemAction: Equatable, Sendable {
    case tryAgain, editEndpoint, startService, newChat, switchModel, openSettings, continueAfterLimit
}

/// "Open this link?" with the full URL (F2): `chat.confirmLink(.cancel | .copy | .open)`.
public struct LinkAsk: Equatable, Sendable, Identifiable {
    public let id: String
    public let question: String
    /// The whole URL, for reading before opening; control characters removed.
    public let url: String
    public let cancel: String
    public let copy: String
    public let open: String
    public let isArmed: Bool
    /// When its buttons start taking input; nil while the HUD isn't key.
    public let armedAt: Date?
}

public indirect enum BlockScreen: Equatable, Sendable {
    case heading(level: Int, InlineText)
    case paragraph(InlineText)
    case list(ListBlock)
    case code(CodeBlock)
    case quote([BlockScreen])
    case table(TableBlock)
    case rule
}

public struct ListBlock: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// "•", "◦" or "–" by depth; "3." in a numbered list; nil for a task item.
        public let marker: String?
        /// A task item's box: true when checked.
        public let checked: Bool?
        public let blocks: [BlockScreen]
    }

    public let ordered: Bool
    public let items: [Item]
    /// 0 for a top-level list.
    public let depth: Int
}

public struct CodeBlock: Equatable, Sendable {
    /// `chat.copyCode(id)`.
    public let id: CodeBlockID
    /// "swift", or "code" when unknown.
    public let language: String
    public let text: String
    /// "Copy"
    public let copy: String
}

public struct TableBlock: Equatable, Sendable {
    public let header: [InlineText]
    public let rows: [[InlineText]]
    public let alignments: [MarkdownTable.Alignment]
}

public typealias InlineText = [InlineRun]

public struct InlineRun: Equatable, Sendable {
    public enum Style: Hashable, Sendable {
        case bold, italic, strike, code
    }

    public let text: String
    public let style: Set<Style>
    public let link: LinkRun?
}

/// A run that is a link: clicking it is `chat.openLink(id)`. The view never sees the URL.
public struct LinkRun: Equatable, Sendable {
    public let id: LinkID
    /// What to draw after the link, in --ink-2: " (evil.example)", or nil.
    public let host: String?
    /// The full URL as display text, cleaned (F16), for the tooltip and the VoiceOver hint. A
    /// String, never a URL: the view never opens it (F2).
    public let help: String?
}

/// Turns one message's blocks into screen blocks, numbering its links and code blocks in the
/// order they appear, the same order `LinkID` and `CodeBlockID` count in.
struct ReplyRenderer {
    let messageID: ChatMessage.ID
    private(set) var destinations: [String] = []
    private(set) var codes: [String] = []

    init(messageID: ChatMessage.ID) {
        self.messageID = messageID
    }

    mutating func render(_ blocks: [Block], depth: Int = 0) -> [BlockScreen] {
        blocks.map { render($0, depth: depth) }
    }

    private mutating func render(_ block: Block, depth: Int) -> BlockScreen {
        switch block {
        case .heading(let level, let inlines): return .heading(level: level, text(inlines))
        case .paragraph(let inlines): return .paragraph(text(inlines))
        case .list(let list):
            let items = list.items.enumerated().map { index, item -> ListBlock.Item in
                let marker: String? =
                    item.checkbox != nil
                    ? nil : list.ordered ? "\(list.start + index)." : ["•", "◦", "–"][min(depth, 2)]
                return ListBlock.Item(
                    marker: marker, checked: item.checkbox, blocks: render(item.blocks, depth: depth + 1))
            }
            return .list(ListBlock(ordered: list.ordered, items: items, depth: depth))
        case .code(let language, let code):
            let id = CodeBlockID(messageID: messageID, index: codes.count)
            codes.append(code)
            return .code(
                CodeBlock(
                    id: id, language: language.map { sanitizeForDisplay($0, max: 30) } ?? Strings.Chat.code,
                    text: stripControls(code), copy: Strings.Chat.copy))
        case .quote(let blocks): return .quote(render(blocks, depth: depth))
        case .table(let table):
            return .table(
                TableBlock(
                    header: table.header.map { text($0) }, rows: table.rows.map { $0.map { text($0) } },
                    alignments: table.alignments))
        case .rule: return .rule
        }
    }

    private mutating func text(_ inlines: [Inline], style: Set<InlineRun.Style> = [], link: LinkRun? = nil)
        -> InlineText
    {
        inlines.flatMap { inline -> InlineText in
            switch inline {
            case .text(let text): return [InlineRun(text: stripControls(text), style: style, link: link)]
            case .code(let code):
                return [InlineRun(text: stripControls(code), style: style.union([.code]), link: link)]
            case .strong(let children): return self.text(children, style: style.union([.bold]), link: link)
            case .emphasis(let children): return self.text(children, style: style.union([.italic]), link: link)
            case .strike(let children): return self.text(children, style: style.union([.strike]), link: link)
            case .softBreak: return [InlineRun(text: " ", style: style, link: link)]
            case .lineBreak: return [InlineRun(text: "\n", style: style, link: link)]
            case .link(let span):
                let id = LinkID(messageID: messageID, index: destinations.count)
                destinations.append(span.destination)
                let host = span.hostLabel.map { " (\(sanitizeForDisplay($0, max: 80)))" }
                let help = LinkPolicy.url(span.destination).map { sanitizeForDisplay($0.absoluteString, max: 2048) }
                var runs = self.text(span.text, style: style, link: LinkRun(id: id, host: nil, help: help))
                if runs.isEmpty {
                    runs = [InlineRun(text: "", style: style, link: LinkRun(id: id, host: nil, help: help))]
                }
                // The host goes after the link's last run, so the view draws it once.
                let last = runs.removeLast()
                runs.append(
                    InlineRun(text: last.text, style: last.style, link: LinkRun(id: id, host: host, help: help)))
                return runs
            }
        }
    }
}

/// Reply text with control and direction characters removed (F16), keeping line breaks and
/// tabs, which a reply's body and code need.
func stripControls(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar.value {
        case 0x09, 0x0A: scalars.append(scalar)
        case 0x00...0x1F, 0x7F, 0x80...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069, 0x061C: continue
        default: scalars.append(scalar)
        }
    }
    return String(scalars)
}

extension Block {
    /// The text without its formatting, for Copy.
    var plainText: String {
        switch self {
        case .heading(_, let inlines), .paragraph(let inlines): inlines.map(\.plainText).joined()
        case .list(let list):
            list.items.enumerated().map { index, item in
                let marker = list.ordered ? "\(list.start + index). " : "- "
                return marker + item.blocks.map(\.plainText).joined(separator: "\n")
            }.joined(separator: "\n")
        case .code(_, let text): text
        case .quote(let blocks): blocks.map(\.plainText).joined(separator: "\n")
        case .table(let table):
            ([table.header] + table.rows).map { $0.map { $0.map(\.plainText).joined() }.joined(separator: "\t") }
                .joined(separator: "\n")
        case .rule: "—"
        }
    }
}

extension ChatStore {
    /// The conversation.
    public var screen: ChatScreen {
        var messages: [MessageScreen] = []
        let now = clock.now
        for item in items {
            switch item {
            case .message(let message) where message.role == .user:
                messages.append(
                    .user(
                        id: message.id, text: stripControls(message.text),
                        accessibilityLabel: Strings.Chat.youSaid(message.text)))
            case .message(let message):
                guard let reply = assistant(message) else { continue }
                messages.append(reply)
                if let pending = pendingLink, pending.link.messageID == message.id {
                    messages.append(
                        .linkAsk(
                            LinkAsk(
                                id: "link-ask", question: Strings.Chat.openLinkQuestion,
                                url: sanitizeForDisplay(pending.url, max: 2048), cancel: Strings.Chat.cancel,
                                copy: Strings.Chat.copy, open: Strings.Chat.open,
                                isArmed: guardAllows(pending.shownAt), armedAt: armedAt(pending.shownAt))))
                }
            case .problem(let problem):
                messages.append(.problem(row(problem, now: now)))
            case .toolResult:
                continue
            }
        }
        return ChatScreen(
            toolbar: ChatScreen.Toolbar(
                new: Strings.Chat.new, newHelp: Strings.Chat.newHelp, stop: isBusy ? Strings.Chat.stop : nil),
            messages: messages)
    }

    private func assistant(_ message: ChatMessage) -> MessageScreen? {
        // A step that only asked for tools has nothing to show.
        if message.text.isEmpty && message.state == .done { return nil }
        var renderer = ReplyRenderer(messageID: message.id)
        let parsedBlocks = blocks(message)
        let screenBlocks = renderer.render(parsedBlocks)
        let model = sanitizeForDisplay(message.model ?? "", max: 64)
        return .assistant(
            AssistantScreen(
                id: message.id, blocks: screenBlocks,
                thinking: message.state == .streaming && message.text.isEmpty ? Strings.Chat.thinking(model) : nil,
                stopped: message.state == .stopped ? Strings.Chat.stopped : nil,
                isStreaming: message.state == .streaming,
                accessibilityLabel: Strings.Chat.modelSaid(
                    model, blocks: parsedBlocks.map(\.spokenText), stopped: message.state == .stopped),
                startedAnnouncement: Strings.Chat.replyStarted(model),
                endedAnnouncement: Strings.Chat.replyEnded(model),
                stoppedAnnouncement: Strings.Chat.replyStopped
            ))
    }

    /// Finds a link's URL, or a code block's text, again in its message.
    func rendered(_ messageID: ChatMessage.ID) -> ReplyRenderer? {
        guard let message = message(messageID) else { return nil }
        var renderer = ReplyRenderer(messageID: messageID)
        _ = renderer.render(blocks(message))
        return renderer
    }
}

extension Block {
    /// How VoiceOver reads the block (Yuki's chat copy): code as "Code block, Swift:" and its
    /// text, a table by its size, a link by its text and host.
    var spokenText: String {
        switch self {
        case .heading(_, let inlines), .paragraph(let inlines): inlines.map(\.spokenText).joined()
        case .list(let list):
            list.items.map { $0.blocks.map(\.spokenText).joined(separator: " ") }.joined(separator: ", ")
        case .code(let language, let text): Strings.Chat.codeBlockSpoken(language: language) + " " + text
        case .quote(let blocks): blocks.map(\.spokenText).joined(separator: " ")
        case .table(let table): Strings.Chat.tableSpoken(columns: table.header.count, rows: table.rows.count)
        case .rule: ""
        }
    }
}

extension Inline {
    var spokenText: String {
        switch self {
        case .strong(let children), .emphasis(let children), .strike(let children):
            children.map(\.spokenText).joined()
        case .link(let span):
            span.text.map(\.spokenText).joined()
                + (span.hostLabel.map { ", " + Strings.Chat.linkSpoken(sanitizeForDisplay($0, max: 80)) } ?? "")
        default: plainText
        }
    }
}
