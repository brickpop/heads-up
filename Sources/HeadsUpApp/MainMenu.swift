import AppKit
import HeadsUpCore

/// The app's main menu. HeadsUp has no Dock icon, so this menu never shows, but text
/// fields find ⌘C, ⌘V, ⌘Z and the other editing keys through its key equivalents.
/// Without it they would do nothing in the prompt.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        // undo: and redo: are the responder actions text views answer; there is no type to
        // write #selector against, hence the double parentheses that mark a deliberate string.
        let edit = NSMenu(title: Strings.EditMenu.edit)
        edit.addItem(item(Strings.EditMenu.undo, Selector(("undo:")), "z"))
        edit.addItem(item(Strings.EditMenu.redo, Selector(("redo:")), "Z"))
        edit.addItem(.separator())
        edit.addItem(item(Strings.EditMenu.cut, #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(Strings.EditMenu.copy, #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(Strings.EditMenu.paste, #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(Strings.EditMenu.selectAll, #selector(NSText.selectAll(_:)), "a"))

        let editItem = NSMenuItem()
        editItem.submenu = edit

        // The first item is the app menu; it stays empty.
        let menu = NSMenu()
        menu.addItem(NSMenuItem())
        menu.addItem(editItem)
        return menu
    }

    /// An item sent to the first responder, with ⌘ and `key` (an uppercase key adds ⇧).
    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }
}
