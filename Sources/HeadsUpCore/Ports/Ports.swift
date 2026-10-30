import Foundation

// The protocols the macOS shell implements (ADR-001 §1, "ports"). Tests and
// previews use the fakes in Fakes.swift.

/// The wall clock.
@MainActor
public protocol Clock: AnyObject {
    var now: Date { get }
}

/// Runs work at a wall-clock date: late after the Mac sleeps, never early.
@MainActor
public protocol Scheduler: AnyObject {
    /// Runs `work` on the main actor at `date`, unless the returned handle is cancelled first.
    func schedule(at date: Date, _ work: @escaping @MainActor () -> Void) -> ScheduledWork
}

/// A pending `Scheduler` job.
@MainActor
public protocol ScheduledWork: AnyObject {
    func cancel()
}

/// The HUD's window. HUDStore shows and hides it; the window reports key changes back
/// through `HUDStore.didBecomeKey()` and `didResignKey()`.
@MainActor
public protocol HUDWindow: AnyObject {
    /// Shows the HUD on the screen under the pointer. With `makeKey`, it takes keyboard focus
    /// without activating the app; without it, it shows over other windows and stays non-key.
    func show(makeKey: Bool)
    func hide()
}

/// Registers the system-wide wake shortcut.
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    /// Registers `shortcut` in place of the current one; `pressed` runs each time it's pressed.
    /// If it fails, the current shortcut stays registered and keeps working.
    func register(_ shortcut: Shortcut, pressed: @escaping @MainActor () -> Void) -> HotkeyStatus

    /// Releases the keys while the shortcut recorder listens, so it can capture them too.
    func suspend()

    /// Registers the current shortcut again after `suspend()`.
    func resume()
}

/// The system's own light or dark appearance, whatever HeadsUp's setting.
@MainActor
public protocol SystemAppearance: AnyObject {
    var isDark: Bool { get }
}

/// Shows a file in Finder, selected.
@MainActor
public protocol FileRevealer: AnyObject {
    func reveal(_ file: URL)
}

/// How opening a command in a terminal went.
public enum TerminalRunResult: Equatable, Sendable {
    case opened
    /// macOS refused HeadsUp's Automation request to control the terminal (-1743).
    case notAllowed
    /// The terminal app isn't there any more.
    case notInstalled
    /// Anything else, in the system's words, for the log and the row.
    case failed(String)
}

/// Finds the terminal apps on this Mac and opens commands in them (ADR-001 §7.3).
@MainActor
public protocol TerminalLauncher: AnyObject {
    /// The terminals installed now, in `Terminal.allCases` order.
    func installed() -> [InstalledTerminal]
    /// Runs `plan`: the script's handler with its parameters, or the argv, never a shell line.
    func run(_ plan: TerminalPlan) async -> TerminalRunResult
}

/// Opens a link from a reply in the default app (F2: only after `LinkPolicy`).
@MainActor
public protocol LinkOpener: AnyObject {
    func open(_ url: URL)
}

/// The clipboard: Copy writes plain text only; ⌘V can read images (F17).
@MainActor
public protocol Pasteboard: AnyObject {
    func copy(_ text: String)
    /// The clipboard holds images, or image files: ⌘V attaches them rather than pasting text.
    var hasImages: Bool { get }
    /// The first `limit` of those images, read, and how many there are in all.
    func readImages(limit: Int) -> OfferedImages
    /// What `clipboard_read` would share (F3). A concealed or transient item, as password
    /// managers mark them, is `.concealed`, and its content is never read.
    func toolContents() -> ClipboardContents
}

/// Whether HeadsUp opens at login, as macOS reports it.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Turned on, but the user must allow it in System Settings → General → Login Items.
    case requiresApproval
    /// macOS can't register this copy of the app (for example, run from a disk image).
    case unavailable
}

extension LoginItemStatus {
    /// The switch shows on: it is on, or the user turned it on and macOS waits for approval.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// Open at Login (`SMAppService.mainApp`). macOS is the source of truth, not settings.json.
@MainActor
public protocol LoginItem: AnyObject {
    var status: LoginItemStatus { get }
    /// Where HeadsUp.app is, to tell whether it runs from an Applications folder.
    var appLocation: URL { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Opens a pane of System Settings.
@MainActor
public protocol SystemSettingsLinks: AnyObject {
    /// General → Login Items, to allow HeadsUp there.
    func openLoginItems()
    /// Keyboard → Keyboard Shortcuts, to free a shortcut macOS uses.
    func openKeyboardShortcuts()
    /// Privacy & Security → Automation, to allow HeadsUp to control a terminal.
    func openAutomation()
    /// Privacy & Security → Calendars or Reminders, after macOS refused a tool.
    func openPrivacy(_ permission: MacPermission)
}

/// The note under the Open at Login row, and its button.
public enum OpenAtLoginNote: Equatable, Sendable {
    /// macOS needs the user's approval. Button: Open Login Items.
    case needsApproval
    /// macOS can't register HeadsUp where it runs. Button: Show in Finder.
    case moveToApplications
    /// macOS couldn't add HeadsUp although it runs from Applications. No button.
    case couldNotAdd
}

/// The kinds of notification HeadsUp posts, with the actions each offers (ADR-001 §7).
public enum NotificationCategory: String, CaseIterable, Sendable {
    /// A focus ended: Start break, Snooze, Done.
    case focusEnd = "focus.end"
    /// A break ended: Start focus, Snooze, Done.
    case breakEnd = "break.end"
    /// A break ended and the next focus started by itself: Stop.
    case breakAutostart = "break.autostart"
    /// A service exited by itself: Show Logs.
    case serviceFailed = "service.failed"

    public var actions: [NotificationAction] {
        switch self {
        case .focusEnd: [.startBreak, .snooze, .done]
        case .breakEnd: [.startFocus, .snooze, .done]
        case .breakAutostart: [.stop]
        case .serviceFailed: [.showLogs]
        }
    }
}

/// A notification's buttons.
public enum NotificationAction: String, CaseIterable, Sendable {
    case startBreak = "start-break"
    case startFocus = "start-focus"
    case snooze
    /// Ends the focus loop: back to idle.
    case done
    case stop
    case showLogs = "show-logs"

    public var title: String { Strings.Notifications.actionTitle(self) }
}

/// One notification, to show at `date`.
public struct NotificationRequest: Equatable, Sendable {
    public let id: String
    public let category: NotificationCategory
    public let title: String
    public let body: String
    public let date: Date
}

/// User notifications (`UNUserNotificationCenter`). The shell registers the categories and
/// their actions at launch and reports each answer to `AppModel.handleNotification`.
@MainActor
public protocol Notifier: AnyObject {
    /// Asks for permission the first time; afterwards it does nothing.
    func requestAuthorization()
    /// Schedules `request`, replacing a pending one with the same id.
    func schedule(_ request: NotificationRequest)
    /// Removes a notification that hasn't been shown yet.
    func cancelPending(id: String)
    /// Removes a shown notification from Notification Center, once its prompt is answered or over.
    func removeDelivered(id: String)
}

/// What a power assertion keeps from happening.
public enum PowerAssertionKind: String, CaseIterable, Sendable {
    /// `PreventUserIdleDisplaySleep`: the display stays on, no screensaver.
    case displaySleep
    /// `PreventUserIdleSystemSleep`: the Mac doesn't go to sleep.
    case systemSleep
}

/// Who holds a power assertion: Caffeine, or a service with Keep awake.
public enum PowerHolder: Hashable, Sendable {
    case caffeine
    case service(ServiceDefinition.ID)
}

/// One power assertion, by who holds it and what it keeps from happening. `name` is only its
/// label in `pmset -g assertions` ("HeadsUp: web-app"): equality and hashing leave it out, so
/// two services with the same name are two holds, and a rename keeps the hold.
public struct PowerHold: Hashable, Sendable {
    public let holder: PowerHolder
    public let kind: PowerAssertionKind
    public let name: String

    public init(holder: PowerHolder, kind: PowerAssertionKind, name: String) {
        self.holder = holder
        self.kind = kind
        self.name = name
    }

    public static func == (lhs: PowerHold, rhs: PowerHold) -> Bool {
        lhs.holder == rhs.holder && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(holder)
        hasher.combine(kind)
    }
}

/// IOKit power assertions (`IOPMAssertionCreateWithName`), one per hold. Declarative: the
/// adapter holds exactly the holds last asked for, creating and releasing assertions as needed.
/// `PowerHolds` is its only caller.
@MainActor
public protocol PowerAssertions: AnyObject {
    /// Holds these and releases any others; an empty set releases all. Returns the holds now
    /// held, which lacks any that macOS refused.
    func hold(_ holds: Set<PowerHold>) -> Set<PowerHold>
}

/// The power source (`IOPSNotificationCreateRunLoopSource`), for "Only on power adapter".
@MainActor
public protocol PowerSource: AnyObject {
    var isOnBattery: Bool { get }
    /// Calls `changed` each time the Mac switches between battery and the power adapter.
    func observe(_ changed: @escaping @MainActor () -> Void)
}
