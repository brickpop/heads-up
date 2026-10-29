import Foundation
import Observation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// Services (ADR-001 §4.2, §6.2, §7.2; Services spec): the definitions in services.json, the
/// processes HeadsUp started, their logs, and the editor.
///
/// A service runs through the login shell in its own process group (see `SpawnPlan` and
/// `POSIXServiceLauncher`), from the environment of the user's terminal (`ShellEnvironment`),
/// read once before the first service starts. Stop sends SIGTERM to the group, and always
/// SIGKILL 3 s later, so children that ignore SIGTERM go too. An exit nobody asked for is `failed`, with a
/// notification and the Services tab's red dot until the user opens Services.
@MainActor
@Observable
public final class ServiceStore {
    /// SIGTERM, then SIGKILL after this long.
    static let killAfter: TimeInterval = 3
    /// A service with no port set counts as running after this long. One that exits sooner
    /// "failed to start": its logs open by themselves.
    static let startWindow: TimeInterval = 3
    /// A service with a port set that is alive this long counts as running, even while its
    /// port is silent.
    static let portWindow: TimeInterval = 30
    /// How often a set port is tried: while starting, then while running but silent.
    static let portCheckWhileStarting: TimeInterval = 1
    static let portCheckWhileSilent: TimeInterval = 5
    /// The UI hears about new output at most this often.
    static let outputInterval: TimeInterval = 0.1

    public private(set) var definitions: [ServiceDefinition] = []
    public private(set) var runtime: [ServiceDefinition.ID: ServiceState] = [:]
    /// Running services whose set port hasn't answered yet: their row says so in --warn.
    public private(set) var silentPorts: Set<ServiceDefinition.ID> = []
    /// The service whose log drawer is open; one at a time.
    public private(set) var openLogs: ServiceDefinition.ID?
    /// Why services.json can't be used. While set, the editor is off and the file is never
    /// written (§6.2).
    public private(set) var loadError: ListFileProblem?
    /// A failure the user hasn't seen: the Services tab shows a red dot until it is opened.
    public private(set) var failureUnseen = false
    /// Services run with HeadsUp's permissions: macOS has no way to start them as their own
    /// responsible process, or refused it for a launch (R10, F5).
    public private(set) var isolationWarning: Bool
    /// The editor in Settings → Services, while open (see ServiceForm.swift).
    public internal(set) var form: ServiceForm?
    private var logs: [ServiceDefinition.ID: LogRing] = [:]

    @ObservationIgnored private var pendingOutput: [ServiceDefinition.ID: Data] = [:]
    @ObservationIgnored private var outputFlush: ScheduledWork?
    /// Services the user asked to stop, so their exit isn't a failure.
    @ObservationIgnored private var stopping: Set<ServiceDefinition.ID> = []
    @ObservationIgnored private var restartAfterStop: Set<ServiceDefinition.ID> = []
    /// The SIGKILL due 3 s after each SIGTERM, by process group.
    @ObservationIgnored private var kills: [Int32: ScheduledWork] = [:]
    /// Leaders that have exited but wait, unreaped, for their group's SIGKILL, so the group id
    /// can't go to another process before it is sent.
    @ObservationIgnored private var unreaped: Set<Int32> = []

    @ObservationIgnored private let file: JSONListFile<ServiceDefinition>
    @ObservationIgnored let clock: Clock
    @ObservationIgnored private let scheduler: Scheduler
    @ObservationIgnored private let launcher: ServiceLauncher
    @ObservationIgnored private let ports: PortProbe
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let files: FileRevealer
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private let loginShell: String
    @ObservationIgnored let home: String
    @ObservationIgnored private let baseEnvironment: [String: String]
    /// Reads the shell's environment; nil starts services from `baseEnvironment` as it is.
    @ObservationIgnored private let shellReader: ShellEnvironmentReader?
    @ObservationIgnored private var shellEnvironment: ShellEnvironmentState
    /// Services started while the shell's environment is read, in order, and whether each toasts.
    /// Their rows look like Starting.
    private var waitingForEnvironment: [(id: ServiceDefinition.ID, toast: Bool)] = []

    /// The environment services start from.
    private enum ShellEnvironmentState {
        /// Not read yet, or being read: starts wait.
        case unread
        /// Read from the shell: the command runs in a plain shell, not a login one, so the login
        /// files don't change PATH again.
        case read([String: String])
        /// HeadsUp's own: no read was asked for (`reason` nil), or it failed. The command runs in a
        /// login shell, as before.
        case own([String: String], reason: String?)
    }

    public init(
        folder: URL?, clock: Clock, scheduler: Scheduler, launcher: ServiceLauncher, ports: PortProbe,
        notifier: Notifier, files: FileRevealer, settings: SettingsStore, toaster: Toaster, loginShell: String,
        home: String, baseEnvironment: [String: String], readsShellEnvironment: Bool = false
    ) {
        file = JSONListFile(.services, folder: folder)
        self.clock = clock
        self.scheduler = scheduler
        self.launcher = launcher
        self.ports = ports
        self.notifier = notifier
        self.files = files
        self.settings = settings
        self.toaster = toaster
        self.loginShell = loginShell
        self.home = home
        self.baseEnvironment = baseEnvironment
        shellReader =
            readsShellEnvironment
            ? ShellEnvironmentReader(
                launcher: launcher, clock: clock, scheduler: scheduler, loginShell: loginShell, home: home,
                baseEnvironment: baseEnvironment) : nil
        shellEnvironment = readsShellEnvironment ? .unread : .own(baseEnvironment, reason: nil)
        isolationWarning = !launcher.canDisclaim
        load()
    }

    // MARK: State

    public func state(_ id: ServiceDefinition.ID) -> ServiceState { runtime[id] ?? .stopped }

    public func logLines(_ id: ServiceDefinition.ID) -> [LogLine] { logs[id]?.lines ?? [] }

    /// Whether the editor may change services.json (not while it can't be used).
    public var canEdit: Bool { loadError == nil }

    /// What the menu bar, the menu and the tab dot need.
    public var snapshot: ServicesSnapshot {
        var snapshot = ServicesSnapshot()
        for state in runtime.values {
            switch state {
            case .running: snapshot.running += 1
            case .starting: snapshot.starting += 1
            case .failed: snapshot.failed += 1
            case .stopped: break
            }
        }
        snapshot.starting += waitingForEnvironment.count
        return snapshot
    }

    /// A service started while the shell's environment is read: it starts once it is.
    func isWaitingForEnvironment(_ id: ServiceDefinition.ID) -> Bool {
        waitingForEnvironment.contains { $0.id == id }
    }

    /// Services that would stop if HeadsUp quit, in their list order.
    public var liveServices: [ServiceDefinition] {
        definitions.filter { state($0.id).isLive }
    }

    /// The notice bar in Services, until dismissed for this version of macOS (UX addendum 4).
    public var showsIsolationNotice: Bool {
        isolationWarning && settings.settings.general.isolationWarningDismissedForOS != Self.osVersion
    }

    public func dismissIsolationNotice() {
        settings.update { $0.general.isolationWarningDismissedForOS = Self.osVersion }
    }

    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    // MARK: Start, stop, restart

    /// Starts every service marked Start with HeadsUp. AppModel calls it at launch.
    public func startAutostart() {
        for definition in definitions where definition.autostart && definition.problems.isEmpty {
            launch(definition, toast: false)
        }
    }

    /// Start. A service from services.json that breaks a rule can't start until it is fixed.
    public func start(_ id: ServiceDefinition.ID) {
        guard let definition = definition(id), definition.problems.isEmpty, !state(id).isLive else { return }
        launch(definition, toast: true)
    }

    /// Stop: SIGTERM to the whole group, then SIGKILL to it 3 s later.
    public func stop(_ id: ServiceDefinition.ID) {
        if let index = waitingForEnvironment.firstIndex(where: { $0.id == id }) {
            waitingForEnvironment.remove(at: index)
            if let definition = definition(id) { toaster?.toast(Strings.Services.stopped(definition.name)) }
            return
        }
        guard let definition = definition(id), let pid = state(id).pid else { return }
        terminate(id, group: pid)
        toaster?.toast(Strings.Services.stopped(definition.name))
    }

    /// Restart a running service: stop it, and start it again once it has exited.
    public func restart(_ id: ServiceDefinition.ID) {
        guard state(id).isLive else { return start(id) }
        restartAfterStop.insert(id)
        stop(id)
    }

    /// Quitting: sends SIGTERM to every service, waits until they have all exited or 3 s have
    /// passed, then sends SIGKILL to every group that had a SIGTERM, whatever is left in it.
    public func stopAll() async {
        shellReader?.cancel()
        waitingForEnvironment = []
        for definition in liveServices {
            if let pid = state(definition.id).pid { terminate(definition.id, group: pid) }
        }
        // Real time, whatever the injected clock says: this waits for real processes.
        let deadline = Date().addingTimeInterval(Self.killAfter)
        while !liveServices.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        for group in Array(kills.keys) { kill(group: group) }
    }

    // MARK: Logs

    /// The Logs button: opens this service's drawer, or closes it. One drawer at a time.
    public func toggleLogs(_ id: ServiceDefinition.ID) {
        openLogs = openLogs == id ? nil : id
    }

    public func clearLogs(_ id: ServiceDefinition.ID) {
        logs[id]?.clear()
    }

    /// The user opened the Services tab: a failure is seen, and the red dot goes.
    public func sawServices() {
        failureUnseen = false
    }

    /// Show Logs, from a notification: Services opens with that service's drawer.
    public func showLogs(_ id: ServiceDefinition.ID) {
        guard definition(id) != nil else { return }
        openLogs = id
        failureUnseen = false
    }

    // MARK: Editing

    /// Saves a service: adds a new one or replaces the one with the same id. Returns the
    /// problems that kept it from being saved, by field; empty when it was saved. A file that
    /// couldn't be written is a `.file` problem, and nothing changes, on disk or here.
    @discardableResult
    public func save(_ definition: ServiceDefinition) -> [ServiceField: String] {
        guard canEdit else { return [.file: Strings.ListFile.cantEdit(.services)] }
        var problems = definition.problems
        var isFolder: ObjCBool = false
        let folder = SpawnPlan.expand(definition.cwd, home: home)
        if problems[.cwd] == nil,
            !FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) || !isFolder.boolValue
        {
            problems[.cwd] = Strings.ListForm.folderMissing
        }
        guard problems.isEmpty else { return problems }

        var trimmed = definition
        trimmed.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = definitions
        let isNew: Bool
        if let index = list.firstIndex(where: { $0.id == definition.id }) {
            list[index] = trimmed
            isNew = false
        } else {
            list.append(trimmed)
            isNew = true
        }
        if let problem = file.write(list) { return [.file: problem] }
        definitions = list
        toaster?.toast(isNew ? Strings.Services.added(trimmed.name) : Strings.Services.saved(trimmed.name))
        return [:]
    }

    /// Remove…, confirmed: a running service is stopped. Returns the problem that kept it from
    /// being removed, as `save` does; empty when it was removed.
    @discardableResult
    public func delete(_ id: ServiceDefinition.ID) -> [ServiceField: String] {
        guard canEdit else { return [.file: Strings.ListFile.cantEdit(.services)] }
        guard let definition = definition(id) else { return [:] }
        if let problem = file.write(definitions.filter { $0.id != id }) { return [.file: problem] }
        if state(id).isLive {
            // Its state and log go when it has exited (see `exited`).
            stop(id)
        } else {
            forget(id)
        }
        definitions.removeAll { $0.id == id }
        if openLogs == id { openLogs = nil }
        toaster?.toast(Strings.Services.removed(definition.name))
        return [:]
    }

    // MARK: services.json problems

    /// Show in Finder, on the services.json problem card.
    public func revealServicesFile() {
        guard let url = file.url else { return }
        files.reveal(url)
    }

    /// Try Again, on the card: reads services.json again, only while it can't be used.
    public func reloadServices() {
        guard loadError != nil else { return }
        loadError = nil
        load()
    }

    // MARK: Inside

    func definition(_ id: ServiceDefinition.ID) -> ServiceDefinition? {
        definitions.first { $0.id == id }
    }

    private func launch(_ definition: ServiceDefinition, toast: Bool) {
        let id = definition.id
        let environment: [String: String]
        var environmentProblem: String?
        switch shellEnvironment {
        case .unread:
            if !isWaitingForEnvironment(id) {
                waitingForEnvironment.append((id, toast))
                log(id, Strings.Services.readingEnvironment)
            }
            readShellEnvironment()
            return
        case .read(let read): environment = read
        case .own(let own, let reason):
            environment = own
            environmentProblem = reason
        }
        let fromShell = if case .read = shellEnvironment { true } else { false }
        let plan = SpawnPlan(
            definition: definition, loginShell: loginShell, home: home, baseEnvironment: environment,
            login: !fromShell)
        let now = clock.now
        // The command only: env values are never written to the log (F11).
        log(id, Strings.Services.commandLine(definition.command))
        log(id, Strings.Services.starting)
        if let shell = plan.shellFallback { log(id, Strings.Services.shellFallback(shell)) }
        if let environmentProblem { log(id, Strings.Services.environmentFallback(environmentProblem)) }

        let launched: LaunchedProcess
        do {
            launched = try launcher.launch(
                plan,
                output: { [weak self] data in
                    Task { @MainActor in self?.received(data, for: id) }
                },
                exit: { [weak self] exit in
                    Task { @MainActor in self?.exited(id, exit) }
                })
        } catch {
            log(id, Strings.Services.couldNotStart(error.description))
            runtime[id] = .failed(exitCode: -1, at: now)
            openLogs = id
            return
        }
        if !launched.isolated {
            log(id, Strings.Services.withoutSeparatePermissions)
            isolationWarning = true
        }
        let pid = launched.pid
        runtime[id] = .starting(pid: pid, since: now)
        silentPorts.remove(id)
        if toast { toaster?.toast(Strings.Services.started(definition.name)) }

        if let port = definition.port {
            // Starting until the port answers; after 30 s alive, running but silent.
            checkPort(id, pid: pid, port: port, at: now.addingTimeInterval(Self.portCheckWhileStarting))
            _ = scheduler.schedule(at: now.addingTimeInterval(Self.portWindow)) { [weak self] in
                guard let self, case .starting(pid, let since) = self.state(id) else { return }
                self.runtime[id] = .running(pid: pid, since: since, port: port)
                self.silentPorts.insert(id)
            }
        } else {
            // Running once it has lasted the start window; its port, if one is found.
            _ = scheduler.schedule(at: now.addingTimeInterval(Self.startWindow)) { [weak self] in
                guard let self, case .starting(pid, let since) = self.state(id) else { return }
                self.runtime[id] = .running(pid: pid, since: since, port: nil)
            }
            for delay in [2.0, 10.0] {
                _ = scheduler.schedule(at: now.addingTimeInterval(delay)) { [weak self] in
                    self?.findPort(id, pid: pid)
                }
            }
        }
    }

    /// Tries the service's set port at `date`, and again until it answers or the process ends.
    private func checkPort(_ id: ServiceDefinition.ID, pid: Int32, port: Int, at date: Date) {
        _ = scheduler.schedule(at: date) { [weak self] in
            guard let self, self.state(id).pid == pid else { return }
            Task { @MainActor in
                let answers = await self.ports.answers(port: port)
                switch self.state(id) {
                case .starting(pid, let since), .running(pid, let since, _):
                    if answers {
                        self.runtime[id] = .running(pid: pid, since: since, port: port)
                        self.silentPorts.remove(id)
                        return
                    }
                    let interval =
                        self.silentPorts.contains(id) ? Self.portCheckWhileSilent : Self.portCheckWhileStarting
                    self.checkPort(id, pid: pid, port: port, at: self.clock.now.addingTimeInterval(interval))
                default:
                    return
                }
            }
        }
    }

    /// Looks for the port of a service with none set.
    private func findPort(_ id: ServiceDefinition.ID, pid: Int32) {
        Task { @MainActor in
            guard let port = await ports.listeningPort(group: pid) else { return }
            // A port that answers means it is up, even within its first seconds.
            switch state(id) {
            case .starting(pid, let since), .running(pid, let since, nil):
                runtime[id] = .running(pid: pid, since: since, port: port)
            default:
                break
            }
        }
    }

    /// SIGTERM to the group, and the SIGKILL due 3 s later.
    private func terminate(_ id: ServiceDefinition.ID, group: Int32) {
        stopping.insert(id)
        launcher.signal(group: group, SIGTERM)
        guard kills[group] == nil else { return }
        kills[group] = scheduler.schedule(at: clock.now.addingTimeInterval(Self.killAfter)) { [weak self] in
            self?.kill(group: group)
        }
    }

    /// SIGKILL to the group, then the leader is reaped if it has exited; if it hasn't, it is
    /// reaped when it does (see `exited`).
    private func kill(group: Int32) {
        kills.removeValue(forKey: group)?.cancel()
        launcher.signal(group: group, SIGKILL)
        if unreaped.remove(group) != nil { launcher.reap(group) }
    }

    private func received(_ data: Data, for id: ServiceDefinition.ID) {
        pendingOutput[id, default: Data()].append(data)
        guard outputFlush == nil else { return }
        outputFlush = scheduler.schedule(at: clock.now.addingTimeInterval(Self.outputInterval)) { [weak self] in
            self?.flushOutput()
        }
    }

    private func flushOutput() {
        outputFlush = nil
        let now = clock.now
        for (id, data) in pendingOutput {
            logs[id, default: LogRing()].append(output: data, at: now)
        }
        pendingOutput = [:]
    }

    private func exited(_ id: ServiceDefinition.ID, _ exit: ProcessExit) {
        flushOutput()
        // The leader stays a zombie while its group's SIGKILL is due, so the group id stays ours.
        if let pid = state(id).pid {
            if kills[pid] != nil { unreaped.insert(pid) } else { launcher.reap(pid) }
        }
        // A service removed while it ran leaves nothing behind once it has exited.
        guard let definition = definition(id) else {
            stopping.remove(id)
            restartAfterStop.remove(id)
            forget(id)
            return
        }
        let now = clock.now
        logs[id]?.flush(at: now)
        silentPorts.remove(id)
        let wasStarting = if case .starting = state(id) { true } else { false }

        switch exit {
        case .code(let code): log(id, Strings.Services.exited(code: code))
        case .signal(let signal): log(id, Strings.Services.killed(signal: Self.signalName(signal)))
        }

        if stopping.remove(id) != nil {
            runtime[id] = .stopped
            if restartAfterStop.remove(id) != nil { launch(definition, toast: true) }
            return
        }

        let code: Int32 =
            switch exit {
            case .code(let code): code
            case .signal(let signal): 128 + signal
            }
        runtime[id] = .failed(exitCode: code, at: now)
        failureUnseen = true
        // "command not found": the user may have just installed it, or changed their PATH.
        if code == 127, shellReader != nil {
            shellEnvironment = .unread
            log(id, Strings.Services.environmentReadAgain)
        }
        // Failed to start: the logs open by themselves (UX part 1, §9).
        if wasStarting { openLogs = id }
        notifier.schedule(
            NotificationRequest(
                id: Self.notificationID(id), category: .serviceFailed,
                title: Strings.Services.failedTitle(definition.name),
                body: Strings.Services.failedBody(code: code), date: now))
    }

    // MARK: The shell's environment

    /// Starts the read, unless it is running or done.
    private func readShellEnvironment() {
        guard let shellReader, case .unread = shellEnvironment, !shellReader.isReading else { return }
        shellReader.read { [weak self] outcome in
            self?.environmentRead(outcome)
        }
    }

    /// The usual tool folders go after the shell's PATH, then the services that waited start.
    private func environmentRead(_ outcome: ShellEnvironmentReader.Outcome) {
        switch outcome {
        case .read(let environment): shellEnvironment = .read(withToolFolders(environment))
        case .failed(let reason):
            shellEnvironment = .own(withToolFolders(baseEnvironment), reason: reason)
        }
        let waiting = waitingForEnvironment
        waitingForEnvironment = []
        for (id, toast) in waiting {
            guard let definition = definition(id), definition.problems.isEmpty, !state(id).isLive else { continue }
            launch(definition, toast: toast)
        }
    }

    private func withToolFolders(_ environment: [String: String]) -> [String: String] {
        guard let path = environment["PATH"] else { return environment }
        var environment = environment
        environment["PATH"] = ShellEnvironment.appendingFolders(ShellEnvironment.usualFolders(home: home), to: path)
        return environment
    }

    /// Drops the state and log of a service that no longer exists, so it counts nowhere.
    private func forget(_ id: ServiceDefinition.ID) {
        runtime[id] = nil
        logs[id] = nil
        pendingOutput[id] = nil
        silentPorts.remove(id)
    }

    private func log(_ id: ServiceDefinition.ID, _ text: String) {
        logs[id, default: LogRing()].appendLine(text, at: clock.now)
    }

    static func notificationID(_ id: ServiceDefinition.ID) -> String { "service.failed:\(id)" }

    /// The service a `service.failed` notification is about, from its request id.
    static func serviceID(fromNotification requestID: String) -> ServiceDefinition.ID? {
        let prefix = "service.failed:"
        guard requestID.hasPrefix(prefix) else { return nil }
        return String(requestID.dropFirst(prefix.count))
    }

    nonisolated static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGKILL: "SIGKILL"
        case SIGINT: "SIGINT"
        case SIGHUP: "SIGHUP"
        default: "signal \(signal)"
        }
    }

    // MARK: services.json

    /// Reads services.json (see `JSONListFile`). A file that can't be used is kept as it is
    /// and never written: the editor stays off.
    private func load() {
        switch file.load() {
        case .success(let list): definitions = list
        case .failure(let problem):
            definitions = []
            loadError = problem
        }
    }
}
