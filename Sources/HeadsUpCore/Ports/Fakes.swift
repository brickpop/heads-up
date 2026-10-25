import Foundation

#if DEBUG
    // Stand-ins for the ports, for tests and SwiftUI previews. Each one does what the
    // real port does, in memory, and lets the caller set what happens.

    /// A clock that only moves when told to.
    @MainActor
    public final class ManualClock: Clock {
        public var now: Date

        public init(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
            self.now = now
        }

        public func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// A scheduler whose jobs run when `runDue()` is called, for those whose date has come.
    @MainActor
    public final class ManualScheduler: Scheduler {
        private let clock: ManualClock
        private var jobs: [(date: Date, handle: Handle, work: @MainActor () -> Void)] = []

        public init(clock: ManualClock) {
            self.clock = clock
        }

        public func schedule(at date: Date, _ work: @escaping @MainActor () -> Void) -> ScheduledWork {
            let handle = Handle()
            jobs.append((date, handle, work))
            return handle
        }

        /// Moves the clock forward and runs every job that is due, in date order.
        public func advance(by seconds: TimeInterval) {
            clock.advance(by: seconds)
            let due = jobs.filter { $0.date <= clock.now }.sorted { $0.date < $1.date }
            jobs.removeAll { $0.date <= clock.now }
            for job in due where !job.handle.isCancelled {
                job.work()
            }
        }

        /// Jobs scheduled and not cancelled yet.
        public var pendingCount: Int { jobs.filter { !$0.handle.isCancelled }.count }

        private final class Handle: ScheduledWork {
            var isCancelled = false
            func cancel() { isCancelled = true }
        }
    }

    /// A window that records what it was asked to do, and reports key changes like the panel.
    @MainActor
    public final class FakeHUDWindow: HUDWindow {
        public private(set) var isVisible = false
        public private(set) var isKey = false
        public private(set) var showCount = 0
        /// Set it to report key changes to this store, as the real panel does.
        public weak var hud: HUDStore?

        public init() {}

        public func show(makeKey: Bool) {
            isVisible = true
            showCount += 1
            if makeKey && !isKey {
                isKey = true
                hud?.didBecomeKey()
            }
        }

        public func hide() {
            isVisible = false
            if isKey {
                isKey = false
                hud?.didResignKey()
            }
        }

        /// The user clicked another app's window.
        public func clickElsewhere() {
            guard isKey else { return }
            isKey = false
            hud?.didResignKey()
        }
    }

    /// A shortcut registrar that returns a set status and lets the caller press the shortcut.
    @MainActor
    public final class FakeHotkeyRegistrar: HotkeyRegistrar {
        /// What the next `register` returns; `.ok` with the shortcut when nil.
        public var nextStatus: HotkeyStatus?
        public private(set) var registered: Shortcut?
        private var pressed: (@MainActor () -> Void)?

        public init(nextStatus: HotkeyStatus? = nil) {
            self.nextStatus = nextStatus
        }

        public func register(_ shortcut: Shortcut, pressed: @escaping @MainActor () -> Void) -> HotkeyStatus {
            let status = nextStatus ?? .ok(shortcut)
            if case .ok = status {
                registered = shortcut
                self.pressed = pressed
            }
            return status
        }

        /// The user pressed the wake shortcut.
        public func press() {
            pressed?()
        }
    }

    /// A system appearance that stays as set.
    @MainActor
    public final class FixedAppearance: SystemAppearance {
        public var isDark: Bool

        public init(isDark: Bool = false) {
            self.isDark = isDark
        }
    }

#endif
