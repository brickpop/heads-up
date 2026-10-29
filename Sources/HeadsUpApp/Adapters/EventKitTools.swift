import EventKit
import Foundation
import HeadsUpCore

/// The calendar and reminders the tools read, through EventKit (ADR-001 §9). Access is asked
/// at the first call of each kind, never at launch: the Calendar prompt for the first calendar
/// read, the Reminders prompt for the first reminders call (R3). A refusal is `blockedByMacOS`.
///
/// Only the fields the tools may share are read: an event's title, times, location and URL,
/// never its notes or attendees (F10).
final class EventKitTools: CalendarReader, RemindersAccess, @unchecked Sendable {
    /// EventKit's store is safe to use from any thread; one serves the whole app.
    private let store = EKEventStore()
    private let prompts: PermissionPrompts

    init(prompts: PermissionPrompts) {
        self.prompts = prompts
    }

    // MARK: Calendar

    func events(from: Date, to: Date) async throws(ToolFailure) -> [CalendarEvent] {
        try await access(.event)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "", start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                location: event.location, url: event.url?.absoluteString)
        }
    }

    // MARK: Reminders

    func lists() async throws(ToolFailure) -> [ReminderList] {
        try await access(.reminder)
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder).map { list in
            let source = list.source
            // Anything that isn't stored only on this Mac may be seen by others (gate decision 3).
            let isShared = source?.sourceType != .local
            let account = source?.title.trimmingCharacters(in: .whitespaces)
            return ReminderList(
                id: list.calendarIdentifier, title: list.title, isDefault: list.calendarIdentifier == defaultID,
                isShared: isShared, account: isShared && account?.isEmpty == false ? account : nil)
        }
    }

    func reminders(listID: String?) async throws(ToolFailure) -> [Reminder] {
        try await access(.reminder)
        var calendars: [EKCalendar]?
        if let listID {
            guard let list = store.calendar(withIdentifier: listID) else { throw .failed("list not found") }
            calendars = [list]
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                let reminders = (found ?? []).map { reminder in
                    Reminder(
                        title: reminder.title ?? "", due: reminder.dueDateComponents?.date,
                        list: reminder.calendar?.title ?? "")
                }
                continuation.resume(returning: reminders)
            }
        }
    }

    func create(title: String, due: Date?, listID: String) async throws(ToolFailure) {
        try await access(.reminder)
        guard let list = store.calendar(withIdentifier: listID) else { throw .failed("list not found") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            let calendar = Calendar.current
            // A due date at midnight is a day without a time.
            let parts: Set<Calendar.Component> =
                due == calendar.startOfDay(for: due) ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute]
            reminder.dueDateComponents = calendar.dateComponents(parts, from: due)
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw .failed(error.localizedDescription)
        }
    }

    // MARK: Access

    /// Asks macOS once; refused, restricted or write-only access blocks the tool.
    private func access(_ type: EKEntityType) async throws(ToolFailure) {
        let permission: MacPermission = type == .event ? .calendar : .reminders
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess:
            return
        case .notDetermined:
            // An error is a refusal too.
            await prompts.begin()
            let granted: Bool?
            if type == .event {
                granted = try? await store.requestFullAccessToEvents()
            } else {
                granted = try? await store.requestFullAccessToReminders()
            }
            await prompts.end()
            guard granted == true else { throw .blockedByMacOS(permission: permission) }
        default:
            throw .blockedByMacOS(permission: permission)
        }
    }
}
