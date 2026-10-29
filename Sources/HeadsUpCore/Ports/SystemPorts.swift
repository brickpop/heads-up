import Foundation

/// The real wall clock.
@MainActor
public final class SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// Runs work at a wall-clock date on the main queue. The wall clock keeps counting
/// while the Mac sleeps, so a deadline that passed during sleep fires right after wake.
///
/// HeadsUp is a menu bar app: with the HUD hidden it has no visible window, and macOS may then
/// put it in App Nap, which delays its timers by minutes. A focus end would then bring only its
/// notification, which Notification Center fires by itself, and not the HUD (card
/// focus-end-auto-open). So while any job waits, the scheduler holds an activity that keeps the
/// app out of App Nap (idle system sleep is still allowed), and each timer is strict, with a
/// small leeway.
@MainActor
public final class SystemScheduler: Scheduler {
    /// How late a job may run, at most, so the system can still group timers a little.
    static let leeway = DispatchTimeInterval.milliseconds(100)

    /// The jobs waiting: the scheduler keeps them, since most callers drop their handle.
    private var jobs: [ObjectIdentifier: Job] = [:]
    #if canImport(Darwin)
        private var activity: NSObjectProtocol?
    #endif

    public init() {}

    /// Jobs scheduled that haven't run or been cancelled.
    var pendingCount: Int { jobs.count }
    /// Whether it keeps the app out of App Nap now: while any job waits.
    private(set) var isHoldingOff = false

    public func schedule(at date: Date, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        let job = Job(timer: timer)
        job.ended = { [weak self, weak job] in
            guard let self, let job else { return }
            self.jobs[ObjectIdentifier(job)] = nil
            self.updateActivity()
        }
        jobs[ObjectIdentifier(job)] = job
        updateActivity()
        timer.schedule(wallDeadline: .now() + max(0, date.timeIntervalSinceNow), leeway: Self.leeway)
        timer.setEventHandler { [weak job] in
            MainActor.assumeIsolated { job?.fire(work) }
        }
        timer.resume()
        return job
    }

    private func updateActivity() {
        let hold = !jobs.isEmpty
        guard hold != isHoldingOff else { return }
        isHoldingOff = hold
        #if canImport(Darwin)
            if hold {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep, reason: "Timers that must end on time")
            } else if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        #endif
    }

    /// One job: its timer, run or cancelled once.
    private final class Job: ScheduledWork {
        private let timer: DispatchSourceTimer
        private var isDone = false
        /// Tells the scheduler it no longer waits.
        var ended: (@MainActor () -> Void)?

        init(timer: DispatchSourceTimer) {
            self.timer = timer
        }

        func fire(_ work: @MainActor () -> Void) {
            guard finish() else { return }
            work()
        }

        func cancel() {
            _ = finish()
        }

        /// False when it had already run or been cancelled.
        private func finish() -> Bool {
            guard !isDone else { return false }
            isDone = true
            timer.cancel()
            ended?()
            ended = nil
            return true
        }
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
