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
