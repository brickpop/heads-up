/// How long Caffeine keeps the Mac awake: the four cards of the Caffeine tab.
public enum CaffeineDuration: String, Codable, CaseIterable, Sendable {
    case fifteenMinutes, oneHour, twoHours, untilOff

    /// Its length in minutes, or nil for Until off.
    public var minutes: Int? {
        switch self {
        case .fifteenMinutes: 15
        case .oneHour: 60
        case .twoHours: 120
        case .untilOff: nil
        }
    }
}

/// Settings → the Caffeine tab's options (ADR-001 §6.1; Caffeine spec).
///
/// The rule holds for any file: keeping the display on and preventing system sleep can't both
/// be off (a file with both off decodes with both on).
public struct CaffeineSettings: Equatable, Codable, Sendable {
    /// The last duration used: the switch, the menu and the autocomplete turn Caffeine on with it.
    public var lastDuration = CaffeineDuration.oneHour
    public var keepDisplayOn = true
    public var preventSystemSleep = true
    /// Pause on battery, resume on the power adapter.
    public var onlyOnAC = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CaffeineSettings()
        lastDuration =
            (try? container.decodeIfPresent(CaffeineDuration.self, forKey: .lastDuration)) ?? defaults.lastDuration
        keepDisplayOn = try container.decodeIfPresent(Bool.self, forKey: .keepDisplayOn) ?? defaults.keepDisplayOn
        preventSystemSleep =
            try container.decodeIfPresent(Bool.self, forKey: .preventSystemSleep) ?? defaults.preventSystemSleep
        onlyOnAC = try container.decodeIfPresent(Bool.self, forKey: .onlyOnAC) ?? defaults.onlyOnAC
        if !keepDisplayOn && !preventSystemSleep {
            keepDisplayOn = true
            preventSystemSleep = true
        }
    }

    /// The power assertions these options ask for.
    public var assertions: Set<PowerAssertionKind> {
        var kinds: Set<PowerAssertionKind> = []
        if keepDisplayOn { kinds.insert(.displaySleep) }
        if preventSystemSleep { kinds.insert(.systemSleep) }
        return kinds
    }
}

/// One of the Caffeine tab's option switches.
public enum CaffeineOption: CaseIterable, Sendable {
    case keepDisplayOn, preventSystemSleep, onlyOnAC
}

/// What macOS refused when Caffeine asked it to keep the Mac awake.
public enum CaffeineAssertionProblem: Equatable, Sendable {
    /// Both, or the only one asked for: Caffeine is off.
    case refused
    /// Keeping the display on; Caffeine stays on with system sleep prevented.
    case displayRefused
    /// Preventing system sleep; Caffeine stays on with the display kept on.
    case systemRefused
}
