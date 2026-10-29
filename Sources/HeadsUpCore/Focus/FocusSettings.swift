/// Settings → Focus (ADR-001 §6.1; Focus spec; UX part 2, §11).
///
/// The rules hold for any file: a value outside its allowed set decodes as the default,
/// options with an empty label are dropped, and an empty list becomes the defaults.
public struct FocusSettings: Equatable, Codable, Sendable {
    /// The focus lengths offered, in minutes.
    public static let focusLengths = [25, 40, 50]
    /// Break and option lengths, in minutes, in the order a click cycles them.
    public static let breakLengths = [2, 5, 10, 20, 50]
    public static let snoozeLengths = [2, 5, 10]
    /// Any length typed (`/start 35`, `/break 7`) or asked for by the focus.timer tool, in whole
    /// minutes. The presets above stay the ones offered and suggested.
    public static let anyFocusRange = 1...180
    public static let anyBreakRange = 1...60
    /// The length the Add field starts with in Settings → Focus.
    public static let newOptionLength = 5

    /// The focus length, the same value as the selected card in the Focus tab.
    public var focusLength = 25
    public var snoozeMinutes = 5
    /// Open the HUD when a session ends; otherwise only a notification.
    public var openHudOnEnd = true
    /// A break that ends by time starts the next focus at once.
    public var autoStartNextFocus = false
    public var breakOptions = BreakOption.defaults

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FocusSettings()
        let length = try container.decodeIfPresent(Int.self, forKey: .focusLength)
        focusLength = length.flatMap { Self.focusLengths.contains($0) ? $0 : nil } ?? defaults.focusLength
        let snooze = try container.decodeIfPresent(Int.self, forKey: .snoozeMinutes)
        snoozeMinutes = snooze.flatMap { Self.snoozeLengths.contains($0) ? $0 : nil } ?? defaults.snoozeMinutes
        openHudOnEnd = try container.decodeIfPresent(Bool.self, forKey: .openHudOnEnd) ?? defaults.openHudOnEnd
        autoStartNextFocus =
            try container.decodeIfPresent(Bool.self, forKey: .autoStartNextFocus) ?? defaults.autoStartNextFocus
        var seen = Set<String>()
        let options = (try container.decodeIfPresent([BreakOption].self, forKey: .breakOptions) ?? [])
            .filter { !$0.label.isEmpty && seen.insert($0.id).inserted }
        breakOptions = options.isEmpty ? defaults.breakOptions : options
    }
}

/// A break activity offered when a focus ends.
public struct BreakOption: Equatable, Codable, Sendable, Identifiable {
    /// An option's id, such as "water", or "custom-…" for one the user added.
    public typealias ID = String

    public let id: String
    public var label: String
    public var icon: BreakIcon
    /// Its default break length in minutes, one of `FocusSettings.breakLengths`.
    public var length: Int

    public init(id: String, label: String, icon: BreakIcon, length: Int) {
        self.id = id
        self.label = label
        self.icon = icon
        self.length = FocusSettings.breakLengths.contains(length) ? length : 5
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            icon: (try? container.decode(BreakIcon.self, forKey: .icon)) ?? .dot,
            length: try container.decodeIfPresent(Int.self, forKey: .length) ?? 5)
    }

    /// The Focus spec's defaults.
    public static let defaults = [
        BreakOption(id: "look", label: "Look elsewhere", icon: .eye, length: 2),
        BreakOption(id: "water", label: "Drink water", icon: .droplet, length: 5),
        BreakOption(id: "stretch", label: "Stretch your arms", icon: .activity, length: 5),
        BreakOption(id: "friends", label: "Ping a friend", icon: .people, length: 10),
        BreakOption(id: "lunch", label: "Have lunch", icon: .utensils, length: 50),
    ]

    /// The activity selected at first: Drink water, or the first option.
    public static let initialID = "water"
}

/// A break option's icon. User-added options get the dot.
public enum BreakIcon: String, Codable, Sendable {
    case eye, droplet, activity, people, utensils, dot

    public var glyph: Glyph {
        switch self {
        case .eye: .eye
        case .droplet: .droplet
        case .activity: .activity
        case .people: .people
        case .utensils: .utensils
        case .dot: .dot
        }
    }
}
