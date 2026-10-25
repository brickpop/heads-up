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

extension Format {
    /// "Oct 25 – Oct 31", or "Oct 25" for one day. `to` is the end of the range: a range that
    /// ends at midnight ends on the day before.
    public static func dateRange(_ from: Date, _ to: Date, calendar: Calendar) -> String {
        let lastInstant = to.addingTimeInterval(-1)
        let first = monthDay(from, calendar: calendar)
        let last = monthDay(max(from, lastInstant), calendar: calendar)
        return first == last ? first : "\(first) – \(last)"
    }

    /// "Oct 25", in the calendar's locale and time zone.
    public static func monthDay(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.locale = calendar.locale ?? .current
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return date.formatted(style)
    }

    /// A reminder's due date on its card: "Today, 9:00 AM", "Tomorrow", "Oct 28, 9:00 AM". A
    /// due date at midnight is a day without a time.
    public static func dueDate(_ date: Date, now: Date, calendar: Calendar) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            day = "Tomorrow"
        } else {
            day = monthDay(date, calendar: calendar)
        }
        guard date != calendar.startOfDay(for: date) else { return day }
        return "\(day), \(time(date, calendar: calendar))"
    }

    /// "9:00 AM" or "09:00", as the locale writes a short time.
    public static func time(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = calendar.locale ?? .current
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return date.formatted(style)
    }

    /// "Mon", the short weekday.
    public static func weekday(_ date: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.locale = calendar.locale ?? .current
        style.timeZone = calendar.timeZone
        style.calendar = calendar
        return date.formatted(style)
    }

    /// "512 B", "2.1 KB", "1.4 MB": what a tool returned.
    public static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        let kilobytes = Double(count) / 1024
        if kilobytes < 1024 { return String(format: "%.1f KB", kilobytes) }
        return String(format: "%.1f MB", kilobytes / 1024)
    }

    /// "1,284", with the thousands separator of en_US: the app's copy is English.
    public static func count(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }
}
