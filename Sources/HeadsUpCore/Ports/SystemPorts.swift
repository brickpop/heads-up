import Foundation

/// The real wall clock.
@MainActor
public final class SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Runs work at a wall-clock date on the main queue. The wall clock keeps counting
/// while the Mac sleeps, so a deadline that passed during sleep fires right after wake.
@MainActor
public final class SystemScheduler: Scheduler {
    public init() {}

    public func schedule(at date: Date, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let handle = Handle()
        let deadline = DispatchWallTime.now() + max(0, date.timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: deadline) {
            MainActor.assumeIsolated {
                guard !handle.isCancelled else { return }
                work()
            }
        }
        return handle
    }

    private final class Handle: ScheduledWork {
        var isCancelled = false
        func cancel() { isCancelled = true }
    }
}

/// The HUD's chat until AppModel attaches the real one: no model, no messages.
@MainActor
public final class NoChat: HUDChat {
    public init() {}
    public var askTarget: AskTarget { .noModel }
    public var hasMessages: Bool { false }
    public var isBusy: Bool { false }
    public func send(_ text: String) {}
    public func stop() {}
    public var hasAttachments: Bool { false }
    public var isSendBlocked: Bool { false }
    public func newChat() {}
    public func togglePin() {}
}
