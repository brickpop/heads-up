import Foundation

/// Time formats shared by the menu bar, the menu, the footer pills and the tabs
/// (App shell spec, "Time format").
public enum Format {
    /// How a time left in seconds becomes whole minutes.
    public enum Rounding: Sendable {
        /// Up: a focus timer with 17 m 01 s left shows `18m`.
        case up
        /// To the nearest minute: caffeine with 17 m 29 s left shows `17m`.
        case nearest
    }

    /// Whole minutes for `seconds` left, never below 1.
    public static func wholeMinutes(_ seconds: TimeInterval, rounding: Rounding) -> Int {
        let minutes = seconds / 60
        let rounded = rounding == .up ? minutes.rounded(.up) : minutes.rounded(.toNearestOrAwayFromZero)
        return max(1, Int(rounded))
    }

    /// `18m`, or `1h 05m` from one hour up.
    public static func minutes(_ seconds: TimeInterval, rounding: Rounding) -> String {
        let total = wholeMinutes(seconds, rounding: rounding)
        if total < 60 { return "\(total)m" }
        let rest = total % 60
        return "\(total / 60)h \(rest < 10 ? "0" : "")\(rest)m"
    }

    /// `18:42`: minutes and seconds, counting the seconds up so a timer never shows 0:00 early.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let rest = total % 60
        return "\(total / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    /// For VoiceOver: "18 minutes", "1 hour 5 minutes".
    public static func spokenMinutes(_ seconds: TimeInterval, rounding: Rounding) -> String {
        let total = wholeMinutes(seconds, rounding: rounding)
        let hours = total / 60
        let minutes = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 || hours == 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        return parts.joined(separator: " ")
    }
}
