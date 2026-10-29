import Foundation

/// The ports the tools read through.
public struct ToolPorts: Sendable {
    public var calendar: CalendarReader
    public var reminders: RemindersAccess

    public init(calendar: CalendarReader, reminders: RemindersAccess) {
        self.calendar = calendar
        self.reminders = reminders
    }
}

/// A tool call checked and ready: its arguments parsed, and what the card and the row show
/// about it. Nothing has been read or changed yet.
struct PreparedCall: Sendable {
    enum Work: Sendable {
        case calendar(from: Date, to: Date)
        /// The list by the name the model gave, looked up only once the call is allowed: before
        /// that, nothing about the user's lists reaches the model or macOS (Rev, slice 10).
        case readReminders(listName: String?)
        /// `list` is nil when the list asked for doesn't exist: the card offers only Deny.
        case createReminder(title: String, due: Date?, list: ReminderList?)
        /// The clipboard as it was when the card was made: what was shown is what is sent.
        case clipboard(ClipboardContents)
        /// A focus or a break to start. `GatedTools` starts it on the main actor, only from idle.
        case focusTimer(TimerRequest)
    }

    let tool: ToolID
    let work: Work
    /// For the row: "Oct 25 – Oct 31", "Groceries", "1,284 characters".
    let summary: String?
    /// For a card: the mono line, e.g. "calendar.events(Oct 25 – Oct 31)", or the masked clipboard.
    let preview: String?
    /// For the write card: Reminder, Due and List (F4).
    let fields: [CardField]
    /// The reminder goes to a list other people may see.
    let isShared: Bool
    /// Set, the reminder can't be added as asked (a list that doesn't exist): no card shows, the
    /// row says this, and the model learns only that it was denied.
    var notAdded: String? = nil
    /// The row's mono call with its arguments, "focus.timer(focus, 35)", in place of the name.
    var call: String? = nil
}

/// A focus or a break of `minutes`, as the focus.timer tool asked for it.
public struct TimerRequest: Equatable, Sendable {
    public let kind: QuickTimer.Kind
    public let minutes: Int
}

/// What a tool returned: the JSON the model reads (inside the F2 c envelope), and what the
/// transcript shows.
struct ToolResult: Sendable {
    let content: String
    /// The size of `content`, for the row (F10, F2 d).
    var bytes: Int { content.utf8.count }
    /// The calendar's events, for the events block.
    let events: [CalendarEvent]?
}

/// A labelled value on a card. Values from the model are cleaned (F16).
public struct CardField: Equatable, Sendable {
    public let label: String
    public let value: String
    /// Drawn in --warn: a list other people see.
    public let isWarning: Bool
}

/// The four tools (ADR-001 §9): their schemas, their arguments, and running them. Arguments
/// decode into fixed fields; anything else in them is ignored, and a bad field runs nothing.
enum LocalTools {
    /// A calendar read covers at most this many days (F10).
    static let maxCalendarDays = 31
    /// A result the model reads is at most this big.
    static let maxResultBytes = 32 * 1024
    /// A reminder title longer than this is refused.
    static let maxTitleLength = 1000
    /// The clipboard's file names the model gets, at most.
    static let maxFileNames = 20

    // MARK: Schemas

    static func specs(_ tools: [ToolID]) -> [LLMTool] {
        tools.map { tool in
            LLMTool(name: tool.apiName, description: description(tool), parameters: Data(schema(tool).utf8))
        }
    }

    private static func description(_ tool: ToolID) -> String {
        switch tool {
        case .calendar:
            "Read the user's calendar events between two dates (at most 31 days). Returns title, start, end, all_day, location and url."
        case .remindersRead: "Read the user's open reminders, from one list or all of them."
        case .remindersCreate:
            "Add a reminder to the user's Reminders. The user approves each one. Use the default list unless the user named one."
        case .clipboard: "Read what is on the user's clipboard. The user may need to approve it."
        case .focusTimer:
            "Start a focus session or a break on the user's Mac timer at once, in whole minutes. It starts only when no focus or break is running, paused or waiting for the user; otherwise nothing starts. Say in your reply what you started, or that it didn't start."
        }
    }

    private static func schema(_ tool: ToolID) -> String {
        switch tool {
        case .calendar:
            """
            {"type":"object","properties":{"from":{"type":"string","description":"ISO 8601 date or date-time"},\
            "to":{"type":"string","description":"ISO 8601 date or date-time, after from"}},"required":["from","to"]}
            """
        case .remindersRead:
            """
            {"type":"object","properties":{"list":{"type":"string","description":"A list's name; omit for all lists"}}}
            """
        case .remindersCreate:
            """
            {"type":"object","properties":{"title":{"type":"string"},\
            "due":{"type":"string","description":"ISO 8601 date or date-time"},\
            "list":{"type":"string","description":"A list's name; omit for the default list"}},"required":["title"]}
            """
        case .clipboard: #"{"type":"object","properties":{}}"#
        case .focusTimer:
            """
            {"type":"object","properties":{"kind":{"type":"string","enum":["focus","break"]},\
            "minutes":{"type":"integer","minimum":1,"maximum":180,\
            "description":"Whole minutes: 1 to 180 for a focus, 1 to 60 for a break"}},"required":["kind","minutes"]}
            """
        }
    }

    // MARK: Preparing

    /// Parses the call's arguments and gathers what its card needs. The clipboard is read here,
    /// so a concealed item is refused before any card shows (F3).
    @MainActor
    static func prepare(
        _ tool: ToolID, arguments: Data, ports: ToolPorts, pasteboard: Pasteboard, now: Date, calendar: Calendar
    ) async throws(ToolFailure) -> PreparedCall {
        let args = try object(arguments)
        switch tool {
        case .calendar:
            guard let from = date(args["from"], calendar: calendar), let asked = date(args["to"], calendar: calendar)
            else { throw .invalidArguments("from and to must be ISO 8601 dates") }
            guard asked > from else { throw .invalidArguments("to must be after from") }
            let limit = calendar.date(byAdding: .day, value: maxCalendarDays, to: from) ?? asked
            let to = min(asked, limit)
            let range = Format.dateRange(from, to, calendar: calendar)
            // A wider request is read for its first 31 days only, and the row says so (F10a).
            let summary = asked > limit ? Strings.Tools.cutTo31Days(range) : range
            return PreparedCall(
                tool: tool, work: .calendar(from: from, to: to), summary: summary,
                preview: "\(tool.displayName)(\(range))", fields: [], isShared: false)
        case .remindersRead:
            let name = try optionalString(args["list"], "list")
            let summary = name.map { clean($0, max: 64) } ?? Strings.Tools.allLists
            return PreparedCall(
                tool: tool, work: .readReminders(listName: name), summary: summary,
                preview: "\(tool.displayName)(\(summary))", fields: [], isShared: false)
        case .remindersCreate:
            guard
                let title = try optionalString(args["title"], "title")?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            else { throw .invalidArguments("title is required") }
            guard title.count <= maxTitleLength else { throw .invalidArguments("title is too long") }
            var due: Date?
            if let text = try optionalString(args["due"], "due") {
                guard let parsed = date(text, calendar: calendar) else {
                    throw .invalidArguments("due must be an ISO 8601 date")
                }
                due = parsed
            }
            // What the card shows is exactly what is written (Scan L1).
            let shownTitle = sanitizeForDisplay(title, max: 0)
            let dueField = CardField(
                label: Strings.Tools.dueField,
                value: due.map { Format.dueDate($0, now: now, calendar: calendar) } ?? Strings.Tools.noDueDate,
                isWarning: false)
            // The write card needs the real list (F4): who will see it. A list that doesn't exist
            // shows no card: the row says why, and the model is told only "denied", so it can't
            // probe list names (Rev, Yuki).
            let lists = try await ports.reminders.lists()
            let name = try optionalString(args["list"], "list")
            let found =
                name.map { name in lists.first { $0.title.caseInsensitiveCompare(name) == .orderedSame } }
                ?? lists.first(where: \.isDefault) ?? lists.first
            guard let list = found else {
                var missing = PreparedCall(
                    tool: tool, work: .createReminder(title: shownTitle, due: due, list: nil),
                    summary: clean(shownTitle, max: 40), preview: nil, fields: [], isShared: false)
                missing.notAdded = name.map { Strings.Tools.noSuchList(clean($0, max: 64)) } ?? Strings.Tools.noLists
                return missing
            }
            var listValue = clean(list.title, max: 64)
            if list.isDefault { listValue = Strings.Tools.defaultList(listValue) }
            if list.isShared {
                listValue += " · " + (list.account.map { clean($0, max: 40) } ?? Strings.Tools.syncedList)
            }
            return PreparedCall(
                tool: tool, work: .createReminder(title: shownTitle, due: due, list: list),
                summary: clean(shownTitle, max: 40), preview: nil,
                fields: [
                    CardField(label: Strings.Tools.reminderField, value: shownTitle, isWarning: false), dueField,
                    CardField(label: Strings.Tools.listField, value: listValue, isWarning: list.isShared),
                ], isShared: list.isShared)
        case .clipboard:
            let contents = pasteboard.toolContents()
            if contents == .concealed { throw .concealedClipboard }
            return PreparedCall(
                tool: tool, work: .clipboard(contents), summary: Strings.Tools.clipboardSummary(contents),
                preview: Strings.Tools.clipboardPreview(contents), fields: [], isShared: false)
        case .focusTimer:
            let request = try timerRequest(arguments)
            let call = "\(tool.displayName)(\(request.kind == .focus ? "focus" : "break"), \(request.minutes))"
            var prepared = PreparedCall(
                tool: tool, work: .focusTimer(request), summary: nil, preview: call, fields: [], isShared: false)
            prepared.call = call
            return prepared
        }
    }

    /// The focus.timer arguments, strictly (Scan C3): `kind` is "focus" or "break", and
    /// `minutes` a JSON number with no fractional part (35.0 is 35) within the kind's bounds.
    /// A string, a boolean, null, a fraction or anything out of bounds runs nothing.
    static func timerRequest(_ arguments: Data) throws(ToolFailure) -> TimerRequest {
        struct KindField: Decodable {
            enum Kind: String, Decodable {
                case focus, `break`
            }
            let kind: Kind
        }
        // A Double, so 35.0 decodes; the decoder refuses strings, booleans and null.
        struct MinutesField: Decodable {
            let minutes: Double
        }
        guard let field = try? JSONDecoder().decode(KindField.self, from: arguments) else {
            throw .invalidArguments(Strings.Tools.timerKindProblem)
        }
        let kind: QuickTimer.Kind = field.kind == .focus ? .focus : .break
        let bounds = Double(kind.range.lowerBound)...Double(kind.range.upperBound)
        guard let minutes = (try? JSONDecoder().decode(MinutesField.self, from: arguments))?.minutes,
            minutes.rounded() == minutes, bounds.contains(minutes)
        else { throw .invalidArguments(Strings.Tools.timerLengthProblem(kind)) }
        return TimerRequest(kind: kind, minutes: Int(minutes))
    }

    // MARK: Running

    /// Reads or writes, after the gate let it through.
    static func run(_ prepared: PreparedCall, ports: ToolPorts) async throws(ToolFailure) -> ToolResult {
        switch prepared.work {
        case .calendar(let from, let to):
            let events = try await ports.calendar.events(from: from, to: to).sorted { $0.start < $1.start }
            return calendarResult(events, from: from, to: to)
        case .readReminders(let name):
            var listID: String?
            if let name {
                let lists = try await ports.reminders.lists()
                guard let list = lists.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw .invalidArguments(Strings.Tools.noSuchList(clean(name, max: 64)))
                }
                listID = list.id
            }
            let reminders = try await ports.reminders.reminders(listID: listID)
            var objects = reminders.map { reminder -> [String: Any] in
                var object: [String: Any] = ["title": reminder.title, "list": reminder.list]
                if let due = reminder.due { object["due"] = iso(due) }
                return object
            }
            return ToolResult(content: capped(key: "reminders", &objects), events: nil)
        case .createReminder(let title, let due, let list):
            guard let list else { throw .failed(Strings.Tools.noReminderList) }
            try await ports.reminders.create(title: title, due: due, listID: list.id)
            return ToolResult(content: json(["added": true, "title": title, "list": list.title]), events: nil)
        case .clipboard(let contents):
            switch contents {
            case .empty: return ToolResult(content: json(["type": "empty"]), events: nil)
            case .concealed: throw .concealedClipboard
            case .text(let text):
                return ToolResult(
                    content: json(["type": "text", "text": prefix(text, bytes: maxResultBytes - 64)]), events: nil)
            case .image(let width, let height):
                return ToolResult(content: json(["type": "image", "width": width, "height": height]), events: nil)
            case .files(let names):
                // Names only, cleaned, at most 20: never paths or contents.
                var objects = names.prefix(maxFileNames).map { ["name": clean($0, max: 255)] as [String: Any] }
                return ToolResult(content: capped(key: "files", &objects, extra: ["count": names.count]), events: nil)
            }
        case .focusTimer:
            // Started by `GatedTools` on the main actor, never here.
            throw .failed(Strings.Tools.notRunHere)
        }
    }

    /// The events as the model reads them: only the allowed fields (F10), cut to 32 KB.
    static func calendarResult(_ events: [CalendarEvent], from: Date, to: Date) -> ToolResult {
        var objects = events.map { event -> [String: Any] in
            var object: [String: Any] = [
                "title": event.title, "start": iso(event.start), "end": iso(event.end), "all_day": event.isAllDay,
            ]
            if let location = event.location { object["location"] = location }
            if let url = event.url { object["url"] = url }
            return object
        }
        let kept = objects.count
        let content = capped(key: "events", &objects, extra: ["from": iso(from), "to": iso(to)])
        return ToolResult(content: content, events: Array(events.prefix(min(kept, objects.count))))
    }

    // MARK: Helpers

    private static func object(_ arguments: Data) throws(ToolFailure) -> [String: Any] {
        if arguments.isEmpty || arguments.allSatisfy({ $0 == 0x20 }) { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: arguments), let object = value as? [String: Any]
        else {
            throw .invalidArguments("the arguments aren't a JSON object")
        }
        return object
    }

    private static func optionalString(_ value: Any?, _ name: String) throws(ToolFailure) -> String? {
        switch value {
        case nil, is NSNull: return nil
        case let text as String: return text
        default: throw .invalidArguments("\(name) must be a string")
        }
    }

    /// "2026-10-25" (local midnight) or a full ISO 8601 date-time, with or without seconds.
    static func date(_ value: Any?, calendar: Calendar) -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let withZone = ISO8601DateFormatter()
        if let date = withZone.date(from: text) { return date }
        withZone.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withZone.date(from: text) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.calendar = calendar
        local.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `{key: [...], …extra, "truncated": true?}`, dropping items from the end until it fits
    /// in 32 KB. `items` is left with the ones kept.
    private static func capped(key: String, _ items: inout [[String: Any]], extra: [String: Any] = [:]) -> String {
        var object = extra
        while true {
            object[key] = items
            let text = json(object)
            if text.utf8.count <= maxResultBytes - 32 || items.isEmpty { return text }
            items.removeLast(max(1, items.count / 10))
            object["truncated"] = true
        }
    }

    private static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.utf8.index(text.startIndex, offsetBy: bytes)
        while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end])
    }

    private static func clean(_ text: String, max: Int) -> String {
        sanitizeForDisplay(text, max: max)
    }
}
