import Foundation

/// One piece of the menu bar item, left to right (ADR-001 §4.3).
public enum StatusItemPart: Equatable, Sendable {
    /// HeadsUp's own glyph, shown only when nothing else is.
    case appGlyph
    /// Focus: the timer glyph (or the pause glyph while paused) and its text.
    /// `warning` draws it in system orange: the user needs to act on it.
    case timer(glyph: Glyph, text: String, warning: Bool)
    /// Caffeine: the cup, with the time left, or no text when it runs until turned off.
    /// `accent` tints the cup with the accent colour while on; slice 4 turns it off while
    /// paused on battery (App shell spec; UX part 2, §15).
    case cup(text: String?, accent: Bool)
}

/// What the menu bar item shows at one moment, and when it next changes.
///
/// It is a pure function of the Focus and Caffeine state and the time, so the status item
/// redraws only at `nextChange`, not every second (ADR-001 §4.3: nothing fires while idle).
public struct StatusItemModel: Equatable, Sendable {
    public let parts: [StatusItemPart]
    /// What VoiceOver reads for the item: "HeadsUp, break due".
    public let accessibilityLabel: String
    /// When the text next changes, or nil when nothing will change by itself.
    public let nextChange: Date?

    /// - Parameters:
    ///   - promptVisible: the HUD is open on the Focus tab, so a waiting prompt is seen
    ///     and its item isn't orange.
    ///   - showSeconds: Settings → General → Show seconds in the menu bar.
    public init(
        focus: FocusSnapshot, caffeine: CaffeineSnapshot, now: Date, promptVisible: Bool, showSeconds: Bool
    ) {
        var parts: [StatusItemPart] = []
        var spoken: [String] = []
        var changes: [Date] = []

        switch focus {
        case .idle, .snoozed:
            break
        case .running(let kind, let endsAt):
            let left = endsAt.timeIntervalSince(now)
            parts.append(.timer(glyph: .timer, text: Self.focusText(left, showSeconds), warning: false))
            spoken.append("\(Strings.MenuBar.kindName(kind)), \(Format.spokenMinutes(left, rounding: .up)) left")
            if let change = Self.nextFocusChange(endsAt: endsAt, now: now, showSeconds: showSeconds) {
                changes.append(change)
            }
        case .paused(let kind, let left):
            parts.append(.timer(glyph: .pause, text: Self.focusText(left, showSeconds), warning: true))
            spoken.append(
                "\(Strings.MenuBar.kindName(kind)) paused, \(Format.spokenMinutes(left, rounding: .up)) left")
        case .prompt(let prompt):
            let words = Strings.MenuBar.promptWords(prompt)
            parts.append(.timer(glyph: .timer, text: words, warning: !promptVisible))
            spoken.append(words.lowercased())
        }

        switch caffeine {
        case .off:
            break
        case .on(nil):
            parts.append(.cup(text: nil, accent: true))
            spoken.append(Strings.MenuBar.caffeineOn)
        case .on(let endsAt?):
            let left = endsAt.timeIntervalSince(now)
            parts.append(.cup(text: Self.caffeineText(left, showSeconds), accent: true))
            spoken.append("\(Strings.MenuBar.caffeineOn), \(Format.spokenMinutes(left, rounding: .nearest)) left")
            if let change = Self.nextCaffeineChange(endsAt: endsAt, now: now, showSeconds: showSeconds) {
                changes.append(change)
            }
        }

        self.parts = parts.isEmpty ? [.appGlyph] : parts
        accessibilityLabel = ([Strings.MenuBar.appName] + spoken).joined(separator: ", ")
        nextChange = changes.min()
    }

    // MARK: Text

    /// Focus: minutes rounded up (`18m`), or `m:ss` always with seconds on.
    static func focusText(_ left: TimeInterval, _ showSeconds: Bool) -> String {
        showSeconds ? Format.clock(left) : Format.minutes(left, rounding: .up)
    }

    /// Caffeine: minutes to the nearest (`58m`, `1h 05m`), or `m:ss` under an hour with seconds on.
    static func caffeineText(_ left: TimeInterval, _ showSeconds: Bool) -> String {
        showSeconds && left < 3600 ? Format.clock(left) : Format.minutes(left, rounding: .nearest)
    }

    // MARK: When the text changes

    /// How long after a rounding boundary the redraw happens, so it lands on the new value.
    static let tick: TimeInterval = 0.001

    /// The next moment the focus text differs: the next whole second, or the next minute
    /// boundary of the time left (shown rounded up).
    static func nextFocusChange(endsAt: Date, now: Date, showSeconds: Bool) -> Date? {
        let left = endsAt.timeIntervalSince(now)
        // Time is up: the store moves to the next phase itself, which redraws the item.
        if left <= 0 { return nil }
        if showSeconds {
            return endsAt.addingTimeInterval(-(left.rounded(.up) - 1))
        }
        let shown = Format.wholeMinutes(left, rounding: .up)
        return endsAt.addingTimeInterval(-Double(shown - 1) * 60)
    }

    /// The next moment the caffeine text differs. Minutes round to the nearest with halves
    /// rounding up (`Format.Rounding.nearest`), so 17:30 left still shows 18m: the text changes
    /// one `tick` after each half-minute mark, never a minute late.
    static func nextCaffeineChange(endsAt: Date, now: Date, showSeconds: Bool) -> Date? {
        let left = endsAt.timeIntervalSince(now)
        if left <= 0 { return nil }
        if showSeconds && left < 3600 {
            return endsAt.addingTimeInterval(-(left.rounded(.up) - 1))
        }
        let shown = Format.wholeMinutes(left, rounding: .nearest)
        if shown <= 1 { return endsAt }
        let change = endsAt.addingTimeInterval(-(Double(shown) - 0.5) * 60 + tick)
        // With seconds on, crossing below an hour switches to m:ss.
        if showSeconds { return min(change, endsAt.addingTimeInterval(-3600 + tick)) }
        return change
    }
}
