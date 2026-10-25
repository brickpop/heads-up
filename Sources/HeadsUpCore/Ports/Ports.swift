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
}

/// The system's own light or dark appearance, whatever HeadsUp's setting.
@MainActor
public protocol SystemAppearance: AnyObject {
    var isDark: Bool { get }
}
