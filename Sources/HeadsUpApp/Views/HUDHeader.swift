import HeadsUpCore
import SwiftUI

/// The header: the six tabs in a row. The active tab expands to fill the row and holds the
/// prompt; the others are 44 × 44 icons, with a dot while their feature is active.
struct HUDHeader: View {
    let hud: HUDStore
    let activity: [Tab: TabActivity]
    /// The model chip, shown in the Chat tab before the prompt.
    var chip: ModelChip?
    /// The images waiting to be sent, before the prompt on any tab, and their × .
    var attachments: [Thumb] = []
    var removeAttachment: @MainActor (Thumb.ID) -> Void = { _ in }
    /// Pinned chats and Attach image, after the prompt in the Chat tab.
    var buttons: ChatButtons?
    var attach: @MainActor () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where each tab sits in the row, for the VoiceOver tab group.
    private let tabFrames = State<[Tab: CGRect]>(initialValue: [:])

    private static let rowSpace = "tabs"

    var body: some View {
        HStack(spacing: HUDStyle.Header.gap) {
            ForEach(Tab.allCases, id: \.self) { tab in
                TabCell(
                    tab: tab, isSelected: hud.tab == tab, activity: activity[tab],
                    select: { hud.selectTab(tab) },
                    reportFrame: { tabFrames.wrappedValue[tab] = $0 }, rowSpace: Self.rowSpace
                ) {
                    HStack(spacing: HUDStyle.Tabs.gap) {
                        if let chip {
                            ModelChipButton(chip: chip, toggle: hud.toggleModelMenu)
                        }
                        if !attachments.isEmpty {
                            AttachmentThumbs(thumbs: attachments, remove: removeAttachment)
                        }
                        PromptField(hud: hud)
                        if let buttons {
                            ChatHeaderButtons(buttons: buttons, togglePinned: hud.togglePinnedList, attach: attach)
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: Self.rowSpace)
        // VoiceOver reads the tabs as a tab group, before the prompt inside the active one.
        .background {
            TabGroupAccessibility(items: accessibilityItems) { hud.selectTab($0) }
                .accessibilitySortPriority(1)
        }
        .padding(HUDStyle.Header.padding)
        .animation(reduceMotion ? nil : HUDStyle.Motion.standard, value: hud.tab)
    }

    private var accessibilityItems: [TabGroupAccessibility.Item] {
        Tab.allCases.map { tab in
            TabGroupAccessibility.Item(
                tab: tab, label: tab.title, isSelected: hud.tab == tab,
                activity: Strings.Tabs.accessibilityValue(tab, selected: false, activity: activity[tab]),
                hint: Strings.Tabs.accessibilityHint(tab), frame: tabFrames.wrappedValue[tab] ?? .zero)
        }
    }
}

/// One tab. Its icon is a button that selects it; when selected, `expanded` shows beside
/// the icon and the tab takes the rest of the row.
private struct TabCell<Expanded: View>: View {
    let tab: Tab
    let isSelected: Bool
    let activity: TabActivity?
    let select: @MainActor () -> Void
    /// Reports the tab's frame in `rowSpace`, for the VoiceOver tab group.
    let reportFrame: @MainActor (CGRect) -> Void
    let rowSpace: String
    @ViewBuilder var expanded: Expanded

    private let isHovered = State(initialValue: false)
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: HUDStyle.Tabs.gap) {
            Button(action: select) {
                Image(systemName: tab.glyph.symbolName)
                    .font(.system(size: HUDStyle.Tabs.iconSize))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    // An inactive tab is all icon button, so a click anywhere on it selects it.
                    .frame(width: isSelected ? HUDStyle.Tabs.iconSize : HUDStyle.Tabs.size, height: HUDStyle.Tabs.size)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Strings.Tabs.tooltip(tab))
            // VoiceOver reads the tab through the tab group behind the row instead.
            .accessibilityHidden(true)

            if isSelected {
                expanded
            }
        }
        .padding(.horizontal, isSelected ? HUDStyle.Tabs.padding : 0)
        .frame(maxWidth: isSelected ? .infinity : HUDStyle.Tabs.size, alignment: .leading)
        .frame(height: HUDStyle.Tabs.size)
        .background(isSelected || isHovered.wrappedValue ? HUDStyle.Colors.raise : Color.clear, in: shape)
        .overlay {
            if isSelected {
                shape.strokeBorder(
                    HUDStyle.Colors.line,
                    lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            }
        }
        .overlay(alignment: .topTrailing) { dot }
        .onHover { isHovered.wrappedValue = $0 }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(rowSpace))
        } action: {
            reportFrame($0)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Tabs.cornerRadius)
    }

    /// The activity dot, on inactive tabs only: accent while active, red after a failure.
    /// VoiceOver reads it through the tab's value.
    @ViewBuilder private var dot: some View {
        if !isSelected, let activity {
            Circle()
                .fill(activity == .alert ? HUDStyle.Colors.alert : Color.accentColor)
                .frame(width: HUDStyle.Tabs.dotSize, height: HUDStyle.Tabs.dotSize)
                .padding(HUDStyle.Tabs.dotInset)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
    struct HUDHeaderPreviews: PreviewProvider {
        static var previews: some View {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HUDHeader(hud: AppModel.preview().hud, activity: [.focus: .active, .services: .alert])
                    .frame(width: HUDLayout.maxWidth)
                    .preferredColorScheme(scheme)
                    .previewDisplayName(scheme == .light ? "Light" : "Dark")
            }
        }
    }
#endif
