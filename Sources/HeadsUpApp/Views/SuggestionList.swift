import HeadsUpCore
import SwiftUI

/// The rows under the prompt. Moving the pointer selects the row it is over, a click runs
/// it, and past 440 pt the list scrolls, keeping the selected row in view.
struct SuggestionList: View {
    let hud: HUDStore

    /// Where the pointer was last seen over the list, in window coordinates. Rows that scroll
    /// or appear under a resting pointer report the same place, so they don't take the
    /// selection from the keyboard: only a pointer that moves selects.
    @State private var lastPointer: CGPoint?

    var body: some View {
        let rows = hud.suggestions
        let selection = hud.selection
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        SuggestionRowView(row: row, isSelected: index == selection)
                            .id(index)
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                if case .active(let location) = phase {
                                    pointerMoved(to: location, over: index)
                                }
                            }
                            .onTapGesture { hud.run(rowAt: index) }
                            .accessibilityLabel(hud.accessibilityLabel(forRow: index))
                            .accessibilityAction { hud.run(rowAt: index) }
                    }
                }
                .padding(HUDStyle.Suggestions.padding)
            }
            // Rows have fixed heights, so the list's height is known without measuring,
            // and the panel can size itself from it.
            .frame(height: min(HUDStyle.Suggestions.maxHeight, Self.contentHeight(rows)))
            .onChange(of: selection) { _, selected in
                guard let selected else { return }
                proxy.scrollTo(selected)
                // The pointer user sees the row they point at; keyboard and typing users hear it.
                if hud.selectionChange != .pointer {
                    AccessibilityNotification.Announcement(hud.accessibilityLabel(forRow: selected)).post()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.Suggestions.accessibilityLabel)
    }

    private func pointerMoved(to location: CGPoint, over index: Int) {
        defer { lastPointer = location }
        guard let lastPointer, lastPointer != location else { return }
        hud.hover(index)
    }

    private static func contentHeight(_ rows: [SuggestionRow]) -> CGFloat {
        let rowsHeight = rows.reduce(CGFloat(0)) { height, row in
            height + (row.isSelectable ? HUDStyle.Suggestions.rowHeight : HUDStyle.Suggestions.noMatchHeight)
        }
        return rowsHeight + 2 * HUDStyle.Suggestions.padding
    }
}

/// One row: icon chip, title, monospace subtitle and kind; the selected row has a gray fill
/// and a ⏎ keycap. "No matching actions" is a plain line.
struct SuggestionRowView: View {
    let row: SuggestionRow
    let isSelected: Bool

    var body: some View {
        switch row {
        case .noMatch(let text):
            Text(text)
                .font(.system(size: HUDStyle.Suggestions.noMatchSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HUDStyle.Suggestions.rowHorizontalPadding)
                .frame(height: HUDStyle.Suggestions.noMatchHeight)
        case .ask, .action:
            content
        }
    }

    private var content: some View {
        HStack(spacing: HUDStyle.Suggestions.rowGap) {
            Image(systemName: row.glyph.symbolName)
                .font(.system(size: HUDStyle.Suggestions.chipIconSize))
                .foregroundStyle(.primary)
                .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                .background(
                    HUDStyle.Colors.chip,
                    in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: HUDStyle.Suggestions.titleSize, weight: .semibold))
                Text(row.subtitle)
                    .font(.system(size: HUDStyle.Suggestions.subtitleSize).monospaced())
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Text(row.kindLabel)
                .font(.system(size: HUDStyle.Suggestions.kindSize))
                .foregroundStyle(.tertiary)
            if isSelected {
                Keycap(key: Strings.Suggestions.runKey)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, HUDStyle.Suggestions.rowVerticalPadding)
        .padding(.horizontal, HUDStyle.Suggestions.rowHorizontalPadding)
        .frame(height: HUDStyle.Suggestions.rowHeight)
        .background(
            isSelected ? HUDStyle.Colors.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.rowCornerRadius)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

#if DEBUG
    struct SuggestionListPreviews: PreviewProvider {
        static var previews: some View {
            Group {
                list(input: "go").previewDisplayName("Free text")
                list(input: "/").previewDisplayName("Slash")
                list(input: "/xyz").previewDisplayName("No match")
                list(input: "/").preferredColorScheme(.dark).previewDisplayName("Slash, dark")
            }
        }

        private static func list(input: String) -> some View {
            let model = AppModel.preview()
            model.hud.setInput(input)
            return SuggestionList(hud: model.hud).frame(width: HUDLayout.maxWidth)
        }
    }
#endif
