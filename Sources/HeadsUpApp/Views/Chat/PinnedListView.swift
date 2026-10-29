import HeadsUpCore
import SwiftUI

/// The Pinned chats list, in the Chat body in place of the conversation: "Pinned chats" with
/// Back to chat, then one row per pinned chat, most recent first, or the empty line. A click
/// loads a chat; × unpins it. Esc goes back to the chat.
struct PinnedListView: View {
    let model: AppModel

    var body: some View {
        let screen = model.pins.screen
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                FocusLabel(text: screen.label)
                Spacer()
                Button(screen.back) { model.hud.togglePinnedList() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, HUDStyle.Services.headerPadding)
            .padding(.vertical, HUDStyle.Footer.keyGap)
            // The list, a load or an unpin failed. Only reading the list offers Try Again:
            // for a chat that didn't open, clicking its row again is the retry.
            if let problem = screen.problem {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    ProblemNote(text: problem.text)
                    if let retry = problem.retry {
                        Button(retry) { model.pins.retry() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, HUDStyle.Services.headerPadding)
                .announcing(problem.text)
            }
            if let empty = screen.empty {
                Text(empty)
                    .font(.system(size: HUDStyle.Settings.labelSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HUDStyle.Services.headerPadding)
                    .padding(.vertical, HUDStyle.Settings.sectionSpacing)
            }
            ForEach(screen.rows, id: \.id) { row in
                PinnedRowView(model: model, row: row)
            }
        }
        .padding(HUDStyle.Suggestions.padding)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(screen.label)
    }
}

/// One pinned chat: the pin chip, its title, "N messages · model", the date, and ×.
private struct PinnedRowView: View {
    let model: AppModel
    let row: PinnedListScreen.Row

    private let isHovered = State(initialValue: false)

    var body: some View {
        HStack(spacing: HUDStyle.Services.rowGap) {
            Button {
                model.loadPinned(row.id)
            } label: {
                HStack(spacing: HUDStyle.Services.rowGap) {
                    Image(systemName: Glyph.pin.symbolName)
                        .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                        .background(
                            HUDStyle.Colors.chip,
                            in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: HUDStyle.Suggestions.titleSize, weight: .semibold))
                            .lineLimit(1)
                        Text(row.meta)
                            .font(.system(size: HUDStyle.Footer.fontSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: HUDStyle.Services.rowGap)
                    Text(row.date)
                        .font(.system(size: HUDStyle.Footer.fontSize).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(row.isLoaded ? [.isSelected] : [])
            Button {
                model.pins.unpin(row.id)
            } label: {
                Image(systemName: Symbols.close)
            }
            .buttonStyle(.borderless)
            .help(row.unpinHelp)
            .accessibilityLabel(row.unpinHelp)
        }
        .padding(HUDStyle.Suggestions.rowVerticalPadding)
        .background(
            row.isLoaded || isHovered.wrappedValue ? HUDStyle.Colors.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.rowCornerRadius)
        )
        .onHover { isHovered.wrappedValue = $0 }
    }
}
