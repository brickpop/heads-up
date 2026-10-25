/// Keycap labels for keys that don't type a character, by virtual key code (Carbon's kVK_
/// values). The shell asks the keyboard layout only for character keys.
public enum KeyNames {
    public static let escape: UInt32 = 53

    /// F1…F20, which may be a shortcut on their own.
    public static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let otherKeys: [UInt32: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// The label for a key that types no character, or nil for a character key.
    public static func name(_ keyCode: UInt32) -> String? {
        functionKeys[keyCode] ?? otherKeys[keyCode]
    }
}

/// Why a recorded shortcut can't be the wake shortcut (UX part 2, §13).
public enum ShortcutProblem: Equatable, Sendable {
    /// It needs ⌘, ⌥ or ⌃, unless it is a function key: a plain letter would fire while typing.
    case needsModifier
    /// HeadsUp itself uses it while the HUD is key: ⌘1…⌘6, ⌘, ⌘N ⌘P ⌘. ⌘Q.
    case usedByHeadsUp
    /// macOS uses it (Spotlight, input sources…).
    case reservedBySystem
    /// Another app registered it.
    case taken
    /// Registration failed for another reason.
    case failed(Int32)
}

extension Shortcut {
    /// Whether this can be a wake shortcut by its keys alone, before registering it:
    /// first the modifier rule, then HeadsUp's own shortcuts (amendment 5).
    public var keysProblem: ShortcutProblem? {
        let hasModifier = !modifiers.isDisjoint(with: [.command, .option, .control])
        let isFunctionKey = KeyNames.functionKeys[keyCode] != nil
        if !hasModifier && !isFunctionKey { return .needsModifier }
        if modifiers == .command && KeyCode.headsUpCommandKeys.contains(keyCode) { return .usedByHeadsUp }
        return nil
    }
}
