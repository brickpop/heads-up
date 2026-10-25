import Foundation

/// Why a tool didn't run (ADR-001 §9). The model is told; the row says it in a few words.
public enum ToolFailure: Error, Equatable, Sendable {
    /// macOS refused the permission, e.g. "Calendar": the row offers Open System Settings.
    case blockedByMacOS(permission: MacPermission)
    /// The clipboard holds a password-manager item (F3).
    case concealedClipboard
    /// The model's arguments don't make sense, e.g. "from must be a date".
    case invalidArguments(String)
    /// Anything else, in a few words.
    case failed(String)
}

/// The macOS privacy permissions the tools need, each with its own pane in System Settings.
public enum MacPermission: String, Equatable, Sendable {
    case calendar, reminders
}

/// One calendar event, with only what `calendar_events` may share: no notes, no attendees
/// (F10). The adapter never reads more than this.
public struct CalendarEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    public let url: String?

    public init(title: String, start: Date, end: Date, isAllDay: Bool, location: String?, url: String?) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.url = url
    }
}

/// The user's calendars, through EventKit on macOS. The adapter asks for access at the first
/// call, never at launch.
public protocol CalendarReader: Sendable {
    /// The events overlapping `from..<to`, by start date. The caller caps the range (F10).
    func events(from: Date, to: Date) async throws(ToolFailure) -> [CalendarEvent]
}

/// A reminders list.
public struct ReminderList: Equatable, Sendable {
    public let id: String
    public let title: String
    /// New reminders go here when the model names no list.
    public let isDefault: Bool
    /// Its EventKit source isn't local-only (iCloud, CalDAV, Exchange…): other people may see
    /// what is added (F4, gate decision).
    public let isShared: Bool
    /// The account's name, "iCloud" or "Google"; nil when it has none.
    public let account: String?

    public init(id: String, title: String, isDefault: Bool, isShared: Bool, account: String?) {
        self.id = id
        self.title = title
        self.isDefault = isDefault
        self.isShared = isShared
        self.account = account
    }
}

/// One open reminder.
public struct Reminder: Equatable, Sendable {
    public let title: String
    public let due: Date?
    public let list: String

    public init(title: String, due: Date?, list: String) {
        self.title = title
        self.due = due
        self.list = list
    }
}

/// The user's reminders, through EventKit on macOS. Access is asked at the first call.
public protocol RemindersAccess: Sendable {
    func lists() async throws(ToolFailure) -> [ReminderList]
    /// The open reminders, of one list or all of them.
    func reminders(listID: String?) async throws(ToolFailure) -> [Reminder]
    /// Adds a reminder; only ever after a card the user allowed (F4).
    func create(title: String, due: Date?, listID: String) async throws(ToolFailure)
}

/// What the clipboard holds, as `clipboard_read` would share it (F3).
public enum ClipboardContents: Equatable, Sendable {
    case empty
    /// A password manager's item, marked concealed or transient: never read, never shared.
    case concealed
    case text(String)
    case image(width: Int, height: Int)
    /// File names only, never their contents.
    case files([String])
}
