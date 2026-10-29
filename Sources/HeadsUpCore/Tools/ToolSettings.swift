/// What the model may do with a tool (Local tools spec; ADR-001 §9).
public enum ToolPermission: String, Codable, CaseIterable, Sendable {
    /// Runs without asking; the row says "Allowed by rule".
    case allow
    /// Asks with a card each time.
    case ask
    /// Never runs, and isn't offered to the model.
    case off
}

/// The local tools, by their permission key in settings.json (ADR-001 §9, R2).
public enum ToolID: String, Codable, CaseIterable, Sendable {
    case calendar, remindersRead, remindersCreate, clipboard, focusTimer

    public enum Effect: Sendable {
        case read, write
        /// Starts something on this Mac that the user sees and can undo, such as a focus timer:
        /// not a write, so it may run on Allow (gate rule 2a). A tool may be one only if it runs
        /// no user-defined command, starts no process, reads and sends no data, is bounded in
        /// time, and is undone by one visible control. Adding one needs a design gate with Scan;
        /// a test pins the list.
        case localControl
    }

    /// The name the API uses: the display name with `.` → `_`.
    public var apiName: String { displayName.replacingOccurrences(of: ".", with: "_") }

    /// "calendar.events", for tool rows and Settings.
    public var displayName: String {
        switch self {
        case .calendar: "calendar.events"
        case .remindersRead: "reminders.read"
        case .remindersCreate: "reminders.create"
        case .clipboard: "clipboard.read"
        case .focusTimer: "focus.timer"
        }
    }

    /// Whether running it changes anything. A write always asks, whatever the settings say (F4).
    public var effect: Effect {
        switch self {
        case .calendar, .remindersRead, .clipboard: .read
        case .remindersCreate: .write
        case .focusTimer: .localControl
        }
    }

    /// The values Settings offers: a write can't be allowed (F4).
    public var allowed: [ToolPermission] { effect == .write ? [.ask, .off] : [.allow, .ask, .off] }

    /// The tool an API name stands for, or nil for a name HeadsUp doesn't have.
    public init?(apiName: String) {
        guard let tool = Self.allCases.first(where: { $0.apiName == apiName }) else { return nil }
        self = tool
    }
}

/// settings.json's `tools`: each tool's permission (ADR-001 §6.1). The defaults are the CEO's:
/// Calendar and Focus timer Allow, the rest Ask.
public struct ToolSettings: Equatable, Codable, Sendable {
    public var calendar: ToolPermission = .allow
    public var remindersRead: ToolPermission = .ask
    public var remindersCreate: ToolPermission = .ask
    public var clipboard: ToolPermission = .ask
    public var focusTimer: ToolPermission = .allow

    public init() {}

    public subscript(_ tool: ToolID) -> ToolPermission {
        get {
            switch tool {
            case .calendar: calendar
            case .remindersRead: remindersRead
            // "allow" never stands for a write, even edited into the file by hand (F4).
            case .remindersCreate: remindersCreate == .allow ? .ask : remindersCreate
            case .clipboard: clipboard
            case .focusTimer: focusTimer
            }
        }
        set {
            let value = tool.allowed.contains(newValue) ? newValue : .ask
            switch tool {
            case .calendar: calendar = value
            case .remindersRead: remindersRead = value
            case .remindersCreate: remindersCreate = value
            case .clipboard: clipboard = value
            case .focusTimer: focusTimer = value
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A value this version doesn't know takes the default, so one bad key doesn't lose the file.
        func value(_ key: CodingKeys, _ fallback: ToolPermission) -> ToolPermission {
            (try? container.decodeIfPresent(ToolPermission.self, forKey: key)) ?? fallback
        }
        let defaults = ToolSettings()
        calendar = value(.calendar, defaults.calendar)
        remindersRead = value(.remindersRead, defaults.remindersRead)
        let create = value(.remindersCreate, defaults.remindersCreate)
        remindersCreate = create == .allow ? .ask : create
        clipboard = value(.clipboard, defaults.clipboard)
        focusTimer = value(.focusTimer, defaults.focusTimer)
    }
}
