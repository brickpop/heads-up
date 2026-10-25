import Foundation

/// What a menu row does when chosen.
public enum MenuAction: Equatable, Sendable {
    case openHUD, focus, toggleCaffeine, services, pinned, settings
}

/// One entry of the menu bar menu (App shell spec, "Menu bar menu").
public enum MenuEntry: Equatable, Sendable {
    /// "HeadsUp", with the wake shortcut on the right, or nothing when it isn't registered.
    case header(title: String, shortcut: String?)
    case row(MenuRow)
    case separator
    /// Quit HeadsUp, ⌘Q. The shell sends it to `NSApp.terminate(_:)`, the same path as the
    /// keyboard's ⌘Q (amendment 4). Slice 5 adds the question about running services there.
    case quit(title: String)
}

public struct MenuRow: Equatable, Sendable {
    public let action: MenuAction
    public let title: String
    public let glyph: Glyph?
    /// The text on the right, e.g. "Focus · 18:42" or "2 running".
    public let value: String?
    /// The value is drawn in system orange: the user needs to act on it (UX part 2, §16).
    public let valueIsWarning: Bool
    /// The row carries an inline switch in this state (Caffeine), instead of a value.
    public let switchIsOn: Bool?
    /// The key equivalent, e.g. "," for ⌘, and "q" for ⌘Q.
    public let commandKey: String?

    public init(
        action: MenuAction, title: String, glyph: Glyph?, value: String? = nil, valueIsWarning: Bool = false,
        switchIsOn: Bool? = nil, commandKey: String? = nil
    ) {
        self.action = action
        self.title = title
        self.glyph = glyph
        self.value = value
        self.valueIsWarning = valueIsWarning
        self.switchIsOn = switchIsOn
        self.commandKey = commandKey
    }
}

/// The menu bar menu's content at one moment. The shell builds an `NSMenu` from it each
/// time the menu opens.
public struct MenuModel: Equatable, Sendable {
    public let entries: [MenuEntry]

    public init(
        hotkey: HotkeyStatus, focus: FocusSnapshot, caffeine: CaffeineSnapshot, services: ServicesSnapshot,
        pinnedChats: Int, now: Date
    ) {
        let shortcut: String? =
            if case .ok(let registered) = hotkey { registered.displayName } else { nil }
        let focusValue = Self.focusValue(focus, now: now)
        let caffeineOn = if case .on = caffeine { true } else { false }
        entries = [
            .header(title: Strings.MenuBar.appName, shortcut: shortcut),
            .row(MenuRow(action: .openHUD, title: Strings.MenuBar.openHUD, glyph: .chat)),
            .separator,
            .row(
                MenuRow(
                    action: .focus, title: Strings.Tabs.title(.focus), glyph: .timer, value: focusValue.text,
                    valueIsWarning: focusValue.warning)),
            .row(
                MenuRow(
                    action: .toggleCaffeine, title: Strings.Tabs.title(.caffeine), glyph: .cup,
                    switchIsOn: caffeineOn)),
            .row(
                MenuRow(
                    action: .services, title: Strings.Tabs.title(.services), glyph: .servers,
                    value: Strings.MenuBar.services(services))),
            .separator,
            .row(
                MenuRow(
                    action: .pinned, title: Strings.MenuBar.pinnedChats, glyph: .pin,
                    value: pinnedChats > 0 ? "\(pinnedChats)" : nil)),
            .row(MenuRow(action: .settings, title: Strings.MenuBar.settings, glyph: .sliders, commandKey: ",")),
            .separator,
            .quit(title: Strings.MenuBar.quit),
        ]
    }

    /// The Focus row's right side (UX part 2, §16). Prompts and pauses are orange here
    /// whether or not the HUD shows them: one colour for one state.
    static func focusValue(_ focus: FocusSnapshot, now: Date) -> (text: String, warning: Bool) {
        switch focus {
        case .idle(let length):
            (Strings.MenuBar.startFocus(length), false)
        case .running(let kind, let endsAt):
            ("\(Strings.MenuBar.kindTitle(kind)) · \(Format.clock(endsAt.timeIntervalSince(now)))", false)
        case .paused(_, let left):
            ("\(Strings.MenuBar.paused) · \(Format.clock(left))", true)
        case .prompt(let prompt):
            (Strings.MenuBar.promptWords(prompt), true)
        case .snoozed(let until):
            ("\(Strings.MenuBar.snoozed) · \(Format.clock(until.timeIntervalSince(now)))", false)
        }
    }
}
