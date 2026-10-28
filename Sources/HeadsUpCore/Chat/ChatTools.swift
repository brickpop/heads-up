import Foundation

/// A tool call in the transcript (Chat spec, message types 2 and 3): its approval card while it
/// waits, then its row, which says what was read and how it was allowed.
public struct ToolRecord: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        /// Waits on the user's choice.
        case waiting(PendingCard)
        case running
        case allowedByRule, approvedOnce, alwaysAllowed, denied, disabled
        /// The model named a tool HeadsUp doesn't have.
        case notAvailable
        case blocked(MacPermission)
        /// The clipboard held a password: nothing shared, no card (F3).
        case concealed
        /// In a few words: "list not found".
        case failed(String)
        /// A reminder that can't be added as asked: "no list named “Secret”". No card showed.
        case notAdded(String)
    }

    public let id: String
    let callID: String
    let tool: ToolID?
    /// The name the model used, cleaned (F16): shown only when it isn't one of ours.
    let name: String
    public internal(set) var status: Status
    /// "Oct 25 – Oct 31", "Groceries", "1,284 characters" (F10, F2 d).
    var summary: String?
    /// What the model got back, in bytes.
    var bytes: Int?
    /// A calendar read's events, for the events block.
    var events: [CalendarEvent]?
}

/// What an approval card shows, fixed when it appears.
public struct PendingCard: Equatable, Sendable {
    let tool: ToolID
    /// The model's name, cleaned.
    let model: String
    let choices: [CardChoice]
    let preview: String?
    let fields: [CardField]
    let isShared: Bool
    /// Its buttons ignore input for 600 ms after (F6).
    let shownAt: Date
}

// MARK: - Screens

/// A tool call's row.
public struct ToolRowScreen: Equatable, Sendable, Identifiable {
    public enum Outcome: String, Equatable, Codable, Sendable {
        /// Green with a check.
        case success
        /// Something went wrong: "Failed · …", "Blocked by macOS". --danger with an × (Rev NIT 1).
        case error
        /// The user's choice, or nothing happened: "Denied", "Disabled in Settings", "Not added · …".
        /// --secondary with an × (Yuki).
        case refused
        /// Still running: no icon.
        case pending
    }

    public let id: String
    public let glyph: Glyph
    /// "Calendar"
    public let label: String
    /// "calendar.events", in mono.
    public let fn: String
    /// "Oct 25 – Oct 31"
    public let summary: String?
    /// "2.1 KB", in mono.
    public let size: String?
    /// "Allowed by rule"
    public let status: String
    public let outcome: Outcome
    /// "Open System Settings", when macOS refused the permission: `AppModel.fixTool(id)`.
    public let fix: String?
    public let accessibilityLabel: String
}

/// An approval card: Deny, Allow once and, for an Ask read, Always allow. Each button calls
/// `chat.decide(id, choice)`, which ignores presses the action guard doesn't allow (F6).
public struct ApprovalCardScreen: Equatable, Sendable, Identifiable {
    public let id: String
    public let glyph: Glyph
    /// "GPT-4o mini wants to read your calendar"
    public let title: String
    /// "Calendar isn’t on your allowlist. Nothing is shared until you approve.", or for a
    /// reminder "Nothing is added until you allow it." / "People who share this list will see it."
    public let subtitle: String
    /// The mono line: "calendar.events(Oct 25 – Oct 31)", or the masked clipboard.
    public let preview: String?
    /// The write card's Reminder, Due and List.
    public let fields: [CardField]
    public let buttons: [CardButton]
    /// Its buttons take input now; the intent checks again itself.
    public let isArmed: Bool
    /// When they start taking input; nil while the HUD isn't key.
    public let armedAt: Date?
    /// What VoiceOver announces when the card appears: the title, then "Allow or deny." (Yuki).
    public let announcement: String
}

public struct CardButton: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case ghost, secondary, primary
    }

    public let choice: CardChoice
    public let title: String
    /// No button is ever the default button (F6): the style is only its look.
    public let style: Style
}

/// The calendar's events as a block after its row, from the tool's own result, never from the
/// model's Markdown.
public struct EventsBlock: Equatable, Sendable, Identifiable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: Int
        /// "09:30–10:00", "Mon 09:30–10:00", "All day"
        public let time: String
        public let title: String
        /// The location, or the meeting link as plain text.
        public let meta: String?
    }

    public let id: String
    public let rows: [Row]
}

/// Settings → Tools.
public struct ToolsSettingsScreen: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: ToolID
        public let glyph: Glyph
        /// "Calendar"
        public let label: String
        /// "Read events"
        public let description: String
        /// "calendar.events", in mono.
        public let fn: String
        /// Allow / Ask / Off, or Ask / Off for Add reminders.
        public let choices: [Choice]
        public let selected: ToolPermission
        /// "Always asks before adding."
        public let help: String?
    }

    public struct Choice: Equatable, Sendable {
        public let permission: ToolPermission
        public let title: String
    }

    public let title: String
    public let intro: String
    public let rows: [Row]
}

extension ToolID {
    public var glyph: Glyph {
        switch self {
        case .calendar: .calendar
        case .remindersRead, .remindersCreate: .check
        case .clipboard: .clipboard
        }
    }
}

// MARK: - The chat's side of tool calls

extension ChatStore: ToolDisplay {
    /// The tools sent with a request: none for a model that can't use tools, and never the
    /// ones set to Off (gate decision 1).
    func offeredToolIDs(_ endpoint: Endpoint) -> [ToolID] {
        endpoint.tools ? ToolGate.offered(settings.settings.tools) : []
    }

    func offeredTools(_ endpoint: Endpoint) -> [LLMTool] {
        var specs = LocalTools.specs(offeredToolIDs(endpoint))
        if offersSuggestions(endpoint) { specs.append(SuggestTool.spec(actions.suggestable)) }
        return specs
    }

    /// `suggest_actions` goes with a request to a model that can use tools, while something
    /// may be suggested.
    func offersSuggestions(_ endpoint: Endpoint) -> Bool {
        endpoint.tools && !actions.suggestable.isEmpty
    }

    /// A card's button: Deny, Allow once or Always allow. False when it was ignored: the card
    /// is gone or answered, or the action guard didn't allow the press (F6).
    @discardableResult
    public func decide(_ cardID: String, _ choice: CardChoice) -> Bool {
        tools.decide(cardID, choice)
    }

    /// A card waits for an answer.
    public var hasPendingCard: Bool { tools.hasPendingCard }

    func record(_ id: String) -> ToolRecord? {
        for item in items {
            if case .tool(let record) = item, record.id == id { return record }
        }
        return nil
    }

    func appendRecord(_ record: ToolRecord) {
        items.append(.tool(record))
    }

    func updateRecord(_ id: String, _ change: (inout ToolRecord) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .tool(var record) = items[index] else {
            return
        }
        change(&record)
        items[index] = .tool(record)
    }

    func awaitingApproval(_ waiting: Bool) {
        if waiting {
            phase = .awaitingApproval
        } else if phase == .awaitingApproval {
            phase = .waiting
        }
    }
}

extension ChatStore {
    // MARK: Screens

    /// A record's row, or its card while it waits.
    func screens(_ record: ToolRecord) -> [MessageScreen] {
        if case .waiting(let card) = record.status {
            return [.approvalCard(cardScreen(record.id, card))]
        }
        var screens: [MessageScreen] = [.toolRow(rowScreen(record))]
        if let events = record.events, !events.isEmpty {
            screens.append(.events(eventsBlock(record.id, events)))
        }
        return screens
    }

    /// A finished record as a pin keeps it; nil while it waits or runs.
    func storedRow(_ record: ToolRecord) -> StoredToolRow? {
        switch record.status {
        case .waiting, .running: return nil
        default:
            let row = rowScreen(record)
            return StoredToolRow(
                toolID: record.tool?.rawValue, fn: row.fn, summary: row.summary, status: row.status,
                outcome: row.outcome)
        }
    }

    /// A kept row, from a loaded pin: no size, no events, no fix.
    func rowScreen(_ id: String, stored: StoredToolRow) -> ToolRowScreen {
        let tool = stored.toolID.flatMap(ToolID.init(rawValue:))
        let label = tool.map(Strings.Tools.label) ?? sanitizeForDisplay(stored.fn, max: 64)
        let fn = sanitizeForDisplay(stored.fn, max: 64)
        let summary = stored.summary.map { sanitizeForDisplay($0, max: 80) }
        let status = sanitizeForDisplay(stored.status, max: 80)
        return ToolRowScreen(
            id: id, glyph: tool?.glyph ?? .sparkle, label: label, fn: fn, summary: summary, size: nil, status: status,
            outcome: stored.outcome, fix: nil, accessibilityLabel: Strings.Tools.rowLabel([label, fn, summary, status]))
    }

    private func rowScreen(_ record: ToolRecord) -> ToolRowScreen {
        let label = record.tool.map(Strings.Tools.label) ?? record.name
        let fn = record.tool?.displayName ?? record.name
        let size = record.bytes.map(Format.bytes)
        let (status, outcome): (String, ToolRowScreen.Outcome) =
            switch record.status {
            case .waiting: (Strings.Tools.waiting, .pending)
            case .running: (Strings.Tools.running, .pending)
            case .allowedByRule: (Strings.Tools.allowedByRule, .success)
            case .approvedOnce: (Strings.Tools.approvedOnce, .success)
            case .alwaysAllowed: (Strings.Tools.alwaysAllowed, .success)
            case .denied: (Strings.Tools.denied, .refused)
            case .disabled: (Strings.Tools.disabled, .refused)
            case .notAvailable: (Strings.Tools.notAvailable, .refused)
            case .notAdded(let reason): (Strings.Tools.notAdded(reason), .refused)
            case .concealed: (Strings.Tools.concealed, .refused)
            case .blocked: (Strings.Tools.blocked, .error)
            case .failed(let reason): (Strings.Tools.failed(reason), .error)
            }
        var fix: String?
        if case .blocked = record.status { fix = Strings.Tools.openSystemSettings }
        return ToolRowScreen(
            id: record.id, glyph: record.tool?.glyph ?? .sparkle, label: label, fn: fn, summary: record.summary,
            size: size, status: status, outcome: outcome, fix: fix,
            accessibilityLabel: Strings.Tools.rowLabel([label, fn, record.summary, size, status]))
    }

    private func cardScreen(_ id: String, _ card: PendingCard) -> ApprovalCardScreen {
        let subtitle: String
        if card.tool.effect == .write {
            subtitle = card.isShared ? Strings.Tools.sharedList : Strings.Tools.nothingAdded
        } else {
            subtitle = Strings.Tools.notAllowlisted(card.tool)
        }
        let hasAlways = card.choices.contains(.alwaysAllow)
        let buttons = card.choices.map { choice -> CardButton in
            switch choice {
            case .deny: CardButton(choice: .deny, title: Strings.Tools.deny, style: .ghost)
            case .allowOnce:
                CardButton(choice: .allowOnce, title: Strings.Tools.allowOnce, style: hasAlways ? .secondary : .primary)
            case .alwaysAllow: CardButton(choice: .alwaysAllow, title: Strings.Tools.alwaysAllow, style: .primary)
            }
        }
        return ApprovalCardScreen(
            id: id, glyph: card.tool.glyph, title: Strings.Tools.cardTitle(card.model, card.tool), subtitle: subtitle,
            preview: card.preview, fields: card.fields, buttons: buttons, isArmed: guardAllows(card.shownAt),
            armedAt: armedAt(card.shownAt),
            announcement: Strings.Tools.cardAnnouncement(Strings.Tools.cardTitle(card.model, card.tool)))
    }

    private func eventsBlock(_ id: String, _ events: [CalendarEvent]) -> EventsBlock {
        let calendar = Calendar.current
        let days = Set(events.map { calendar.startOfDay(for: $0.start) })
        let rows = events.enumerated().map { index, event -> EventsBlock.Row in
            var time =
                event.isAllDay
                ? Strings.Tools.allDay
                : "\(Format.time(event.start, calendar: calendar))–\(Format.time(event.end, calendar: calendar))"
            if days.count > 1 { time = "\(Format.weekday(event.start, calendar: calendar)) \(time)" }
            let meta = (event.location?.isEmpty == false ? event.location : event.url).map {
                sanitizeForDisplay($0, max: 120)
            }
            return EventsBlock.Row(id: index, time: time, title: sanitizeForDisplay(event.title, max: 200), meta: meta)
        }
        return EventsBlock(id: id + "-events", rows: rows)
    }
}

extension ToolEnvelope {
    /// `{"tool": …, "error": …}`: a call that didn't run, in the same envelope.
    static func make(tool: String, error: String) -> String {
        let object: [String: Any] = ["tool": tool, "error": error]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
