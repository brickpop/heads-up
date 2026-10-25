import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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

        public private(set) var isSuspended = false

        public func suspend() { isSuspended = true }
        public func resume() { isSuspended = false }

        /// The user pressed the wake shortcut. Nothing happens while it is suspended.
        public func press() {
            guard !isSuspended else { return }
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

    /// Records the files it was asked to show.
    @MainActor
    public final class FakeFileRevealer: FileRevealer {
        public private(set) var revealed: [URL] = []
        public init() {}
        public func reveal(_ file: URL) { revealed.append(file) }
    }

    /// Terminals the test installs, and the plans run, with the result the test sets.
    @MainActor
    public final class FakeTerminalLauncher: TerminalLauncher {
        public var terminals: [Terminal]
        /// What the next runs return.
        public var result: TerminalRunResult = .opened
        public private(set) var ran: [TerminalPlan] = []

        public init(terminals: [Terminal] = [.terminal]) {
            self.terminals = terminals
        }

        public func installed() -> [InstalledTerminal] {
            terminals.map { InstalledTerminal(terminal: $0, appPath: "/Applications/\($0.name).app") }
        }

        public func run(_ plan: TerminalPlan) async -> TerminalRunResult {
            ran.append(plan)
            return result
        }
    }

    /// Remembers the links opened.
    @MainActor
    public final class FakeLinkOpener: LinkOpener {
        public private(set) var opened: [URL] = []
        public init() {}
        public func open(_ url: URL) { opened.append(url) }
    }

    /// Remembers what was copied.
    @MainActor
    public final class FakePasteboard: Pasteboard {
        public private(set) var copied: [String] = []
        public init() {}
        public func copy(_ text: String) { copied.append(text) }
    }

    /// A folder panel that answers what the test says, and remembers where it opened.
    @MainActor
    public final class FakeFolderPicker: FolderPicker {
        /// The folder the user picks; nil is Cancel.
        public var answer: String?
        public private(set) var openedAt: [String] = []
        public init() {}
        public func chooseFolder(startingAt path: String) async -> String? {
            openedAt.append(path)
            return answer
        }
    }

    /// A login item that changes when told to, or fails when `failure` is set.
    @MainActor
    public final class FakeLoginItem: LoginItem {
        public var status: LoginItemStatus
        public var failure: (any Error)?
        public var appLocation: URL

        public struct NotFound: Error {}

        public init(
            status: LoginItemStatus = .disabled,
            appLocation: URL = URL(fileURLWithPath: "/Applications/HeadsUp.app")
        ) {
            self.status = status
            self.appLocation = appLocation
        }

        /// Like SMAppService: an app macOS can't register stays `.unavailable` and throws.
        public func setEnabled(_ enabled: Bool) throws {
            if let failure { throw failure }
            if status == .unavailable { throw NotFound() }
            status = enabled ? .enabled : .disabled
        }
    }

    /// Records which System Settings panes were opened.
    @MainActor
    public final class FakeSystemSettingsLinks: SystemSettingsLinks {
        public private(set) var opened: [String] = []
        public init() {}
        public func openLoginItems() { opened.append("loginItems") }
        public func openKeyboardShortcuts() { opened.append("keyboardShortcuts") }
        public func openAutomation() { opened.append("automation") }
    }

    /// Records what was scheduled and cancelled.
    @MainActor
    public final class FakeNotifier: Notifier {
        public private(set) var pending: [String: NotificationRequest] = [:]
        /// Shown in Notification Center: moved here from `pending` by `deliverDue(at:)`.
        public private(set) var delivered: [String: NotificationRequest] = [:]
        public private(set) var authorizationRequests = 0

        public init() {}

        public func requestAuthorization() { authorizationRequests += 1 }
        public func schedule(_ request: NotificationRequest) { pending[request.id] = request }
        public func cancelPending(id: String) { pending[id] = nil }
        public func removeDelivered(id: String) { delivered[id] = nil }

        /// What macOS does at each date: shows the pending notifications that are due.
        public func deliverDue(at now: Date) {
            for (id, request) in pending where request.date <= now {
                delivered[id] = request
                pending[id] = nil
            }
        }
    }

    /// Holds what it is asked to, and can be told to refuse.
    @MainActor
    public final class FakePowerAssertions: PowerAssertions {
        public private(set) var held: Set<PowerAssertionKind> = []
        /// The kinds macOS refuses, as set by the test.
        public var refused: Set<PowerAssertionKind> = []

        public init() {}

        public func hold(_ kinds: Set<PowerAssertionKind>) -> Set<PowerAssertionKind> {
            held = kinds.subtracting(refused)
            return held
        }
    }

    /// A power source the test switches between battery and AC.
    @MainActor
    public final class FakePowerSource: PowerSource {
        public private(set) var isOnBattery: Bool
        private var changed: (@MainActor () -> Void)?

        public init(isOnBattery: Bool = false) {
            self.isOnBattery = isOnBattery
        }

        public func observe(_ changed: @escaping @MainActor () -> Void) {
            self.changed = changed
        }

        /// The user unplugged (true) or plugged in (false).
        public func set(onBattery: Bool) {
            isOnBattery = onBattery
            changed?()
        }
    }

    /// Launches nothing: the test emits output and exits, and sees the signals sent.
    @MainActor
    public final class FakeServiceLauncher: ServiceLauncher {
        public var canDisclaim = true
        /// Set to make macOS refuse the disclaim for each launch from now on.
        public var refuseDisclaim = false
        /// Set to make the next launch fail.
        public var failNextLaunch: LaunchError?
        public private(set) var launched: [Int32: SpawnPlan] = [:]
        public private(set) var signals: [(group: Int32, signal: Int32)] = []
        /// Every signal and reap, in order: "TERM 1001", "KILL 1001", "reap 1001".
        public private(set) var events: [String] = []
        private var outputs: [Int32: @Sendable (Data) -> Void] = [:]
        private var exits: [Int32: @Sendable (ProcessExit) -> Void] = [:]
        private var nextPID: Int32 = 1000

        public init() {}

        public func launch(
            _ plan: SpawnPlan, output: @escaping @Sendable (Data) -> Void,
            exit: @escaping @Sendable (ProcessExit) -> Void
        ) throws(LaunchError) -> LaunchedProcess {
            if let failure = failNextLaunch {
                failNextLaunch = nil
                throw failure
            }
            nextPID += 1
            launched[nextPID] = plan
            outputs[nextPID] = output
            exits[nextPID] = exit
            return LaunchedProcess(pid: nextPID, isolated: canDisclaim && !refuseDisclaim)
        }

        public func signal(group: Int32, _ signal: Int32) {
            signals.append((group, signal))
            let name = signal == SIGTERM ? "TERM" : signal == SIGKILL ? "KILL" : "\(signal)"
            events.append("\(name) \(group)")
        }

        public func reap(_ pid: Int32) {
            events.append("reap \(pid)")
        }

        /// The process wrote `text`.
        public func emit(_ pid: Int32, _ text: String) {
            outputs[pid]?(Data(text.utf8))
        }

        /// The process ended.
        public func finish(_ pid: Int32, _ exit: ProcessExit) {
            exits[pid]?(exit)
            exits[pid] = nil
        }
    }

    /// A port probe that answers what the test says.
    @MainActor
    public final class FakePortProbe: PortProbe {
        /// The port the service's group listens on, for `listeningPort`.
        public var port: Int?
        /// The ports that answer on this Mac, for `answers`.
        public var answering: Set<Int> = []
        public init(port: Int? = nil) { self.port = port }
        public func listeningPort(group: Int32) async -> Int? { port }
        public func answers(port: Int) async -> Bool { answering.contains(port) }
    }

    /// A model server the test scripts by path ending: "models" → (200, `{"data":[…]}`). It
    /// records every request as sent, `Authorization` included.
    public final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private var scripted: [String: (status: Int, body: String)] = [:]
        private var failing: HTTPError?

        public init() {}

        /// Answers requests whose path ends with `path`.
        public func answer(_ path: String, status: Int = 200, body: String = "") {
            lock.withLock { scripted[path] = (status, body) }
        }

        /// Makes every request fail, or succeed again with nil.
        public func fail(with error: HTTPError?) {
            lock.withLock { failing = error }
        }

        public var requests: [URLRequest] { lock.withLock { recorded } }

        public func send(_ request: URLRequest) async throws -> HTTPResponse {
            let (failure, answer) = lock.withLock { () -> (HTTPError?, (status: Int, body: String)?) in
                recorded.append(request)
                let path = request.url?.path ?? ""
                return (failing, scripted.first { path.hasSuffix($0.key) }?.value)
            }
            if let failure { throw failure }
            let (status, body) = answer ?? (404, "")
            let (stream, continuation) = AsyncThrowingStream<[UInt8], Error>.makeStream()
            continuation.yield(Array(body.utf8))
            continuation.finish()
            return HTTPResponse(status: status, headers: [:], body: stream)
        }
    }

    /// A model the test speaks for: each request opens a stream the test feeds with `say`,
    /// `finish` or `fail`, and the request's messages are kept.
    public final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [AsyncThrowingStream<LLMEvent, Error>.Continuation] = []
        private var sent: [[LLMMessage]] = []

        public init() {}

        public func stream(endpoint: Endpoint, messages: [LLMMessage], tools: [LLMTool])
            -> AsyncThrowingStream<LLMEvent, Error>
        {
            let (stream, continuation) = AsyncThrowingStream<LLMEvent, Error>.makeStream()
            lock.withLock {
                streams.append(continuation)
                sent.append(messages)
            }
            return stream
        }

        /// The messages of each request, in order.
        public var requests: [[LLMMessage]] { lock.withLock { sent } }

        private var current: AsyncThrowingStream<LLMEvent, Error>.Continuation? { lock.withLock { streams.last } }

        public func say(_ events: LLMEvent...) {
            for event in events { current?.yield(event) }
        }

        public func finish(_ reason: StopReason = .stop) {
            current?.yield(.finished(reason, nil))
            current?.finish()
        }

        public func fail(_ error: ChatError) {
            current?.finish(throwing: error)
        }
    }

#endif
