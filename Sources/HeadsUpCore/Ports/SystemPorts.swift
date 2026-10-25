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

/// The HUD's chat until the chat slice: no messages, and Ask names the active model.
@MainActor
public final class NoChat: HUDChat {
    /// The active model's name, set by AppModel once the endpoints exist.
    var activeModel: @MainActor () -> String? = { nil }
    public init() {}
    public var askTarget: AskTarget { activeModel().map { .model(name: $0) } ?? .noModel }
    public var hasMessages: Bool { false }
    public func send(_ text: String) {}
}
