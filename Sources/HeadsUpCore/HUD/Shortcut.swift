/// A key with modifiers: the wake shortcut, or a key pressed while the HUD is key.
///
/// `keyCode` is the macOS virtual key code, the same on every keyboard layout.
/// `key` is what the keycap shows, a display cache: the app fills it from the current
/// keyboard layout and refreshes it at launch and when the input source changes (slice 2),
/// so the core never needs the layout. Equality ignores it.
public struct Shortcut: Hashable, Codable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let keyCode: UInt32
    public let modifiers: Modifiers
    public let key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌥ Space, the default wake shortcut.
    public static let wakeDefault = Shortcut(keyCode: KeyCode.space, modifiers: .option, key: "Space")

    /// One string per keycap, modifiers first in the macOS order: ["⌥", "Space"].
    public var keycaps: [String] {
        var caps: [String] = []
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        return caps + [key]
    }

    /// The shortcut as text: "⌥ Space", "⌘K".
    public var displayName: String {
        let symbols = keycaps.dropLast().joined()
        if symbols.isEmpty { return key }
        return key.count > 1 ? "\(symbols) \(key)" : symbols + key
    }

    /// Two shortcuts are the same keys whatever their labels say.
    public static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers)
    }
}

/// The macOS virtual key codes the core needs (the same values as Carbon's kVK_ constants).
public enum KeyCode {
    public static let space: UInt32 = 49
    public static let comma: UInt32 = 43
    public static let period: UInt32 = 47
    public static let n: UInt32 = 45
    public static let p: UInt32 = 35
    public static let q: UInt32 = 12
    public static let returnKey: UInt32 = 36
    public static let keypadEnter: UInt32 = 76
    public static let leftArrow: UInt32 = 123
    public static let rightArrow: UInt32 = 124
    /// ⌘1…⌘6, by the keys' position.
    public static let digits: [UInt32] = [18, 19, 20, 21, 23, 22]
    /// The keys HeadsUp uses with ⌘ alone: ⌘1…⌘6, ⌘, ⌘N ⌘P ⌘. ⌘Q, ⌘← ⌘→ for the tabs, and ⌘↩ on the
    /// Focus tab.
    public static let headsUpCommandKeys: Set<UInt32> = Set(
        digits + [comma, n, p, period, q, returnKey, keypadEnter, leftArrow, rightArrow])
}

/// Whether the wake shortcut works, known at launch (ADR-001 §4.1).
public enum HotkeyStatus: Equatable, Sendable {
    case ok(Shortcut)
    /// macOS uses it (⌘ Space for Spotlight, ⌃ Space for input sources…).
    case reservedBySystem
    /// Another app registered it first.
    case taken
    /// Registration failed for another reason, with the OSStatus.
    case failed(Int32)
}
