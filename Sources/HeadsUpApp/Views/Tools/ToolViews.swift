import HeadsUpCore
import SwiftUI

/// A tool call in the chat: the 22 pt chip, the label, the mono function, what was asked and
/// how much came back (F10), and the status: a green check when it worked, a red × when it
/// failed, a secondary × when it was refused, nothing while it waits. A macOS refusal adds Open System Settings.
struct ToolRowView: View {
    let model: AppModel
    let row: ToolRowScreen

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap * 2) {
            Image(systemName: row.glyph.symbolName)
                .frame(width: HUDStyle.Tools.rowChipSize, height: HUDStyle.Tools.rowChipSize)
                .background(HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius + 2))
                .accessibilityHidden(true)
            // When space runs out, the summary is cut first; the status always shows.
            Text(row.label)
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            Text(row.fn)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            if let summary = row.summary {
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let size = row.size {
                Text(size)
                    .monospaced()
                    .foregroundStyle(.secondary)
            }
            Separator()
            HStack(spacing: HUDStyle.Footer.keyGap) {
                switch row.outcome {
                case .success:
                    Image(systemName: Glyph.check.symbolName).foregroundStyle(HUDStyle.Colors.running)
                case .error:
                    Image(systemName: Symbols.close).foregroundStyle(HUDStyle.Colors.alert)
                case .refused:
                    Image(systemName: Symbols.close).foregroundStyle(.secondary)
                case .pending:
                    EmptyView()
                }
                Text(row.status)
                    .foregroundStyle(statusColor)
            }
            .lineLimit(1)
            .fixedSize()
            .layoutPriority(2)
            if let fix = row.fix {
                Button(fix) { model.fixTool(row.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: HUDStyle.Tools.rowFontSize))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// Green when it worked, red when it failed or macOS blocked it, secondary when it was
    /// refused on purpose (denied, off in Settings) or is still waiting.
    private var statusColor: Color {
        switch row.outcome {
        case .success: HUDStyle.Colors.running
        case .error: HUDStyle.Colors.alert
        case .refused, .pending: .secondary
        }
    }
}

/// The small dot between a tool row's call and its status.
private struct Separator: View {
    var body: some View {
        Circle()
            .fill(.tertiary)
            .frame(width: HUDStyle.Tools.separatorSize, height: HUDStyle.Tools.separatorSize)
            .accessibilityHidden(true)
    }
}

/// An approval card: what the model wants, why it asks, the call or the parsed fields, and
/// Deny · Allow once (· Always allow for reads). No button is the default; they stay dim until
/// the guard lifts (F6), and the core ignores early presses. Announced when it appears; it
/// turns into its tool row in place once answered.
struct ApprovalCardView: View {
    let chat: ChatStore
    let card: ApprovalCardScreen

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HUDStyle.Tools.cardCornerRadius)
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            HStack(alignment: .top, spacing: HUDStyle.Services.rowGap) {
                Image(systemName: card.glyph.symbolName)
                    .font(.system(size: HUDStyle.Suggestions.chipIconSize))
                    .frame(width: HUDStyle.Tools.cardChipSize, height: HUDStyle.Tools.cardChipSize)
                    .background(
                        HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: HUDStyle.Chat.bodySize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(card.subtitle)
                        .font(.system(size: HUDStyle.Footer.fontSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let preview = card.preview {
                Text(preview)
                    .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HUDStyle.Footer.keyGap * 2)
                    .background(
                        HUDStyle.Colors.codeBackground, in: RoundedRectangle(cornerRadius: HUDStyle.Tools.previewRadius)
                    )
            }
            if !card.fields.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: HUDStyle.Services.rowGap) {
                    ForEach(Array(card.fields.enumerated()), id: \.offset) { index, field in
                        GridRow {
                            Text(field.label)
                                .foregroundStyle(.secondary)
                            CardFieldValue(field: field, canFold: index == 0)
                        }
                    }
                }
                .font(.system(size: HUDStyle.Settings.labelSize))
            }
            ArmedTimeline(armedAt: card.armedAt) { isArmed in
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    Spacer()
                    ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                        CardButtonView(button: button) { _ = chat.decide(card.id, button.choice) }
                    }
                }
                .opacity(isArmed ? 1 : HUDStyle.Chat.unarmedOpacity)
            }
        }
        .padding(HUDStyle.Tools.cardPadding)
        .background(HUDStyle.Colors.raise, in: shape)
        .overlay(
            shape.strokeBorder(
                HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
        .accessibilityElement(children: .contain)
        .announcing(card.announcement)
    }
}

/// A card field's value: --warn for a list others see. The Reminder (the first field) folds
/// to three lines, with Show all.
private struct CardFieldValue: View {
    let field: CardField
    let canFold: Bool

    private let expanded = State(initialValue: false)
    /// The value's height in full, and folded to three lines: Show all appears only when they
    /// differ, so a short Reminder has no button.
    private let fullHeight = State<CGFloat>(initialValue: 0)
    private let foldedHeight = State<CGFloat>(initialValue: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.value)
                .foregroundStyle(field.isWarning ? HUDStyle.Colors.warn : Color.primary)
                .lineLimit(canFold && !expanded.wrappedValue ? HUDStyle.Tools.reminderLines : nil)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    if !expanded.wrappedValue { foldedHeight.wrappedValue = $0 }
                }
                .background {
                    Text(field.value)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fullHeight.wrappedValue = $0
                        }
                }
            if canFold && (expanded.wrappedValue || fullHeight.wrappedValue > foldedHeight.wrappedValue + 1) {
                Button(expanded.wrappedValue ? Strings.Tools.showLess : Strings.Tools.showAll) {
                    expanded.wrappedValue.toggle()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }
}

/// A card button in its style: ghost, secondary or primary. Never the default button.
private struct CardButtonView: View {
    let button: CardButton
    let press: @MainActor () -> Void

    var body: some View {
        let control = Button(button.title, action: press).controlSize(.small)
        switch button.style {
        case .ghost: control.buttonStyle(.borderless)
        case .secondary: control.buttonStyle(.bordered)
        case .primary: control.buttonStyle(.borderedProminent)
        }
    }
}

/// Calendar events from a tool result: a bordered list with the time range as a 96 pt keycap,
/// the title, the location or link as plain text, and a calendar glyph.
struct EventsBlockView: View {
    let block: EventsBlock

    var body: some View {
        SettingsList {
            ForEach(Array(block.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Hairline() }
                HStack(spacing: HUDStyle.Services.rowGap) {
                    Keycap(key: row.time)
                        .frame(width: HUDStyle.Tools.eventTimeWidth, height: HUDStyle.Tools.eventTimeHeight)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                        if let meta = row.meta {
                            Text(meta)
                                .font(.system(size: HUDStyle.Footer.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: Glyph.calendar.symbolName)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
                .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
