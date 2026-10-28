import AppKit
import HeadsUpCore
import SwiftUI

/// The HUD tabs as VoiceOver reads a native tab bar: an AXTabGroup whose tabs are AXRadioButtons,
/// each with its label, selected state, activity and ⌘n hint (UX part 2, §21).
///
/// SwiftUI on macOS 14 has no tab role, so this AppKit view sits behind the tab row. It takes no
/// clicks, and the SwiftUI tab buttons are hidden from VoiceOver in its favour. Pressing a tab
/// with VoiceOver selects it, as a click does.
struct TabGroupAccessibility: NSViewRepresentable {
    struct Item: Equatable {
        let tab: Tab
        let label: String
        let isSelected: Bool
        /// What the tab's dot means ("timer running"), or empty.
        let activity: String
        /// "⌘2"
        let hint: String
        /// The tab's frame in the row, from its top-left corner.
        let frame: CGRect
    }

    let items: [Item]
    let select: @MainActor (Tab) -> Void

    func makeNSView(context: Context) -> TabGroupView {
        TabGroupView()
    }

    func updateNSView(_ view: TabGroupView, context: Context) {
        view.update(items: items, select: select)
    }
}

/// The tab group itself: invisible, transparent to the mouse, and the parent of one radio
/// button element per tab.
final class TabGroupView: NSView {
    /// One element per tab, made once and updated in place: VoiceOver keeps its cursor on an
    /// element, so a new element on each update would lose it.
    private var elements: [Tab: TabElement] = [:]
    private var tabs: [TabElement] = []
    private var selected: Tab?

    // Frames come from SwiftUI, measured from the top-left corner.
    override var isFlipped: Bool { true }

    // Clicks go to the SwiftUI tabs on top of the same place.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(items: [TabGroupAccessibility.Item], select: @escaping @MainActor (Tab) -> Void) {
        tabs = items.map { item in
            let element = elements[item.tab] ?? makeElement(for: item.tab)
            element.select = select
            element.setAccessibilityLabel(item.label)
            element.setAccessibilityValue(NSNumber(value: item.isSelected ? 1 : 0))
            element.setAccessibilityValueDescription(item.activity.isEmpty ? nil : item.activity)
            element.setAccessibilityHelp(item.hint)
            element.setAccessibilityFrameInParentSpace(item.frame)
            return element
        }
        let newSelected = items.first { $0.isSelected }?.tab
        guard newSelected != selected else { return }
        // VoiceOver reads "selected" on the new tab and drops it from the old one.
        for tab in [selected, newSelected].compactMap({ $0 }) {
            if let element = elements[tab] {
                NSAccessibility.post(element: element, notification: .valueChanged)
            }
        }
        selected = newSelected
    }

    private func makeElement(for tab: Tab) -> TabElement {
        let element = TabElement(tab: tab)
        element.setAccessibilityRole(.radioButton)
        element.setAccessibilityParent(self)
        elements[tab] = element
        return element
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityChildren() -> [Any]? { tabs }
    override func accessibilityTabs() -> [Any]? { tabs }
}

/// One tab, as a radio button. VoiceOver's press selects it.
final class TabElement: NSAccessibilityElement {
    private let tab: Tab
    /// The header's current action, set on each update.
    var select: (@MainActor (Tab) -> Void)?

    init(tab: Tab) {
        self.tab = tab
        super.init()
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { select?(tab) }
        return true
    }
}
