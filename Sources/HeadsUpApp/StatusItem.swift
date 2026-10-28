import AppKit
import HeadsUpCore

/// The menu bar item (ADR-001 §7): drawn from `AppModel.statusItem`, redrawn when the model
/// changes and at the model's `nextChange`, never on a timer of its own. A left click goes
/// to `statusItemClicked()`; a right click or Control-click opens the menu, built each time
/// from `AppModel.menu`.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let scheduler: Scheduler
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var redraw: ScheduledWork?
    /// The actions of the open menu's rows, by NSMenuItem tag.
    private var rowActions: [MenuAction] = []

    private static let menuWidth: CGFloat = 280
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    init(model: AppModel, scheduler: Scheduler) {
        self.model = model
        self.scheduler = scheduler
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        track(
            { (model.statusItem, model.statusItemHighlighted) },
            apply: { [weak self] state in
                self?.draw(state.0, highlighted: state.1)
            })
    }

    // MARK: Drawing

    private func draw(_ status: StatusItemModel, highlighted: Bool) {
        guard let button = item.button else { return }
        button.highlight(highlighted)
        button.setAccessibilityLabel(status.accessibilityLabel)

        if status.parts == [.appGlyph] {
            let glyph = NSImage(named: "MenuBarGlyph")
            glyph?.isTemplate = true
            button.image = glyph
            button.attributedTitle = NSAttributedString()
        } else {
            button.image = nil
            button.attributedTitle = Self.title(for: status.parts)
        }

        // Redraw when the text next changes by itself, e.g. 18m → 17m.
        redraw?.cancel()
        redraw = status.nextChange.map { date in
            scheduler.schedule(at: date) { [weak self] in
                guard let self else { return }
                self.draw(self.model.statusItem, highlighted: self.model.statusItemHighlighted)
            }
        }
    }

    /// The timer item first, then the cup, each a glyph and its text. A warning part is
    /// system orange, glyph and text; everything else uses the menu bar's own colours.
    private static func title(for parts: [StatusItemPart]) -> NSAttributedString {
        let title = NSMutableAttributedString()
        for part in parts {
            let symbol: String
            let text: String?
            let warning: Bool
            /// The glyph's own colour, or nil for the menu bar's template colour.
            let glyphColor: NSColor?
            switch part {
            case .appGlyph:
                continue
            case .timer(let glyph, let label, let isWarning):
                symbol = glyph.symbolName
                text = label
                warning = isWarning
                glyphColor = isWarning ? .systemOrange : nil
            case .cup(let label, let accent):
                symbol = Glyph.cup.symbolName
                text = label
                warning = false
                glyphColor = accent ? .controlAccentColor : nil
            }
            if title.length > 0 { title.append(NSAttributedString(string: "  ")) }
            title.append(symbolAttachment(symbol, color: glyphColor))
            if let text {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .baselineOffset: 1]
                if warning { attributes[.foregroundColor] = NSColor.systemOrange }
                title.append(NSAttributedString(string: " " + text, attributes: attributes))
            }
        }
        return title
    }

    /// An SF Symbol in `color`, or as a template image the menu bar tints when `color` is nil.
    private static func symbolAttachment(_ name: String, color: NSColor?) -> NSAttributedString {
        var configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let color {
            configuration = configuration.applying(.init(paletteColors: [color]))
        }
        let attachment = NSTextAttachment()
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = color == nil
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    // MARK: Clicks and the menu

    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            showMenu()
        } else {
            model.statusItemClicked()
        }
    }

    private func showMenu() {
        let menu = buildMenu(model.menu)
        menu.delegate = self
        // Attaching the menu for one click gives the native look and placement.
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.menuWillOpen()
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
        model.menuDidClose()
    }

    private func buildMenu(_ content: MenuModel) -> NSMenu {
        let menu = NSMenu()
        menu.minimumWidth = Self.menuWidth
        menu.autoenablesItems = false
        rowActions = []
        for entry in content.entries {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .header(let title, let shortcut):
                let header = NSMenuItem()
                header.attributedTitle = Self.rowTitle(
                    title, value: shortcut, bold: true, warning: false)
                header.isEnabled = false
                menu.addItem(header)
            case .row(let row):
                menu.addItem(menuItem(for: row))
            case .quit(let title):
                // The same path as the keyboard's ⌘Q: applicationShouldTerminate decides.
                menu.addItem(
                    NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            }
        }
        return menu
    }

    private func menuItem(for row: MenuRow) -> NSMenuItem {
        rowActions.append(row.action)
        let menuItem = NSMenuItem(
            title: row.title, action: #selector(chose(_:)), keyEquivalent: row.commandKey ?? "")
        menuItem.target = self
        menuItem.tag = rowActions.count - 1
        if let glyph = row.glyph {
            menuItem.image = NSImage(systemSymbolName: glyph.symbolName, accessibilityDescription: nil)
        }
        if let isOn = row.switchIsOn {
            menuItem.view = switchRow(row, isOn: isOn, tag: menuItem.tag)
        } else if row.value != nil {
            menuItem.attributedTitle = Self.rowTitle(
                row.title, value: row.value, bold: false, warning: row.valueIsWarning)
        }
        return menuItem
    }

    /// A row with an inline switch on the right (Caffeine).
    private func switchRow(_ row: MenuRow, isOn: Bool, tag: Int) -> NSView {
        let label = NSTextField(labelWithString: row.title)
        // The same font as the menu's other rows (Yuki).
        label.font = .menuFont(ofSize: 0)
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .mini
        toggle.tag = tag
        toggle.target = self
        toggle.action = #selector(switched(_:))
        toggle.setAccessibilityLabel(row.title)
        var views: [NSView] = []
        if let glyph = row.glyph,
            let image = NSImage(systemSymbolName: glyph.symbolName, accessibilityDescription: nil)
        {
            let glyphView = NSImageView(image: image)
            // Tinted like the other rows' glyphs, not the accent colour.
            glyphView.contentTintColor = .labelColor
            views.append(glyphView)
        }
        views += [label, NSView(), toggle]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: Self.menuWidth, height: 28)
        return stack
    }

    /// "Title" with "Value" right-aligned on the same line, through a right tab stop.
    private static func rowTitle(_ title: String, value: String?, bold: Bool, warning: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: menuWidth - 40)]
        let titleFont = bold ? NSFont.menuFont(ofSize: 0).withWeight(.semibold) : NSFont.menuFont(ofSize: 0)
        let result = NSMutableAttributedString(
            string: title, attributes: [.font: titleFont, .paragraphStyle: paragraph])
        if let value {
            result.append(
                NSAttributedString(
                    string: "\t" + value,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                        .foregroundColor: warning ? NSColor.systemOrange : NSColor.secondaryLabelColor,
                        .paragraphStyle: paragraph,
                    ]))
        }
        return result
    }

    @objc private func chose(_ sender: NSMenuItem) {
        run(rowActions[sender.tag])
    }

    @objc private func switched(_ sender: NSSwitch) {
        run(rowActions[sender.tag])
    }

    private func run(_ action: MenuAction) {
        model.perform(action)
    }
}

extension NSFont {
    fileprivate func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
