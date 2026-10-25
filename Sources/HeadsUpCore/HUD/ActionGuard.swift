import Foundation

/// When a button that lets the model act, or opens what it wrote, may take input (threat
/// model F6, S2): only while the HUD is key, 600 ms after the button appeared, and 600 ms after
/// the HUD became key, so the click that brings the HUD forward never presses it. One rule for
/// the link ask and Continue now, and for approval cards and confirms later.
public enum ActionGuard {
    public static let delay: TimeInterval = 0.6

    /// The moment a button shown at `shownAt` starts taking input, or nil while the HUD isn't
    /// key. `keySince` is when the HUD last became key.
    public static func armedAt(shownAt: Date, keySince: Date?) -> Date? {
        guard let keySince else { return nil }
        return max(shownAt, keySince).addingTimeInterval(delay)
    }

    /// Whether the button takes input at `now`.
    public static func allows(shownAt: Date, keySince: Date?, now: Date) -> Bool {
        guard let armedAt = armedAt(shownAt: shownAt, keySince: keySince) else { return false }
        return now >= armedAt
    }
}
