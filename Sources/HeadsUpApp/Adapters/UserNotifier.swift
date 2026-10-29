import Foundation
import HeadsUpCore
import UserNotifications

/// Notifications through `UNUserNotificationCenter` (ADR-001 §7). It registers the core's
/// categories with their action buttons, schedules requests at their dates, and passes each
/// answer to `onResponse` as the category and action identifiers (nil for a click on the body),
/// with the request's own id.
@MainActor
final class UserNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var askedForAuthorization = false
    private let prompts: PermissionPrompts
    private let onResponse: @MainActor (_ category: String, _ action: String?, _ requestID: String) -> Void

    init(
        prompts: PermissionPrompts,
        onResponse: @escaping @MainActor (_ category: String, _ action: String?, _ requestID: String) -> Void
    ) {
        self.prompts = prompts
        self.onResponse = onResponse
        super.init()
        center.delegate = self
        center.setNotificationCategories(
            Set(
                NotificationCategory.allCases.map { category in
                    UNNotificationCategory(
                        identifier: category.rawValue,
                        actions: category.actions.map { action in
                            UNNotificationAction(identifier: action.rawValue, title: action.title, options: [])
                        },
                        intentIdentifiers: [], options: [])
                }))
    }

    func requestAuthorization() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        // Answered at once if the user has decided before; otherwise after the prompt.
        prompts.begin()
        center.requestAuthorization(options: [.alert, .sound]) { [prompts] _, _ in
            Task { @MainActor in prompts.end() }
        }
    }

    func schedule(_ request: NotificationRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.categoryIdentifier = request.category.rawValue
        content.sound = .default
        // A calendar date, to the second, rather than an interval: it holds across sleep and
        // clock changes, like the core's own end dates.
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: max(request.date, Date().addingTimeInterval(1)))
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: trigger))
    }

    func cancelPending(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func removeDelivered(id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show it even while HeadsUp is active: the HUD may be closed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The system waits for this to return before it treats the answer as handled. Everything is
    /// read from `response` here, so only plain strings cross to the main actor.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let category = response.notification.request.content.categoryIdentifier
        let requestID = response.notification.request.identifier
        let action: String?
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: action = nil
        // A dismissal is not an answer: the prompt keeps waiting.
        case UNNotificationDismissActionIdentifier: return
        default: action = response.actionIdentifier
        }
        await MainActor.run { self.onResponse(category, action, requestID) }
    }
}
