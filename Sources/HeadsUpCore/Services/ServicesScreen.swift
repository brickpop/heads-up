import Foundation

/// What the Services tab shows at one moment, ready to draw (contract, slice 5), as
/// `FocusScreen` and `CaffeineScreen` do. The view calls `ServiceStore.screen(at:)` each second.
public struct ServicesScreen: Equatable, Sendable {
    /// "Services · 2 running"
    public let label: String
    /// "Logs are always recorded, hidden until you open them"; nil while there are no rows.
    public let note: String?
    /// The header's "Edit…": `AppModel.openServicesSettings()`.
    public let edit: String
    /// The --warn notice bar while services can't have their own permissions (R10).
    public let isolationNotice: IsolationNotice?
    /// While services.json can't be used: shown in place of the list or the empty state.
    public let fileProblem: FileProblemCard?
    /// Shown in place of the list when there are no services.
    public let empty: Empty?
    public let rows: [Row]

    public struct IsolationNotice: Equatable, Sendable {
        public let title: String
        public let text: String
        /// "OK": `dismissIsolationNotice()`.
        public let ok: String
    }

    public struct Empty: Equatable, Sendable {
        public let title: String
        public let text: String
        /// "Add a service…": `AppModel.addService()`.
        public let add: String
    }

    public enum Status: Equatable, Sendable {
        /// A gray dot.
        case stopped
        /// An accent ring.
        case starting
        /// A green dot.
        case running
        /// A --danger dot with a small ×.
        case failed
    }

    /// The colour of a row's meta line.
    public enum MetaStyle: Equatable, Sendable {
        /// --ink-2
        case secondary
        /// The accent colour: running.
        case accent
        /// --warn: running while its port is silent, or a service that can't start.
        case warn
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: ServiceDefinition.ID
        public let name: String
        public let status: Status
        /// ":3000 · 42m", "Starting… waiting for :3000", "Running · nothing on :3000 yet",
        /// "Exited with code 1 · 2 min ago", "Restarting in 5 s · stopped by SIGTERM" (--warn,
        /// counting down), "Kept stopping since 3:12 PM · gave up after 5 restarts",
        /// "Can't start · enter a command to run", or nil.
        public let meta: String?
        public let metaStyle: MetaStyle
        /// "npm run dev · ~/code/web-app"
        public let commandLine: String
        /// Keep the Mac awake while it runs: the cup glyph after the meta.
        public let keepsAwake: Bool
        /// Restart if it stops: the arrow glyph after the meta.
        public let restarts: Bool
        public let logsOpen: Bool
        /// A small --warn dot on the Logs toggle: running while its port is silent.
        public let logsWarning: Bool
        /// The row's button.
        public let action: RowAction
        /// "Web dev server, running, keeps your Mac awake while it runs, restarts if it stops"
        public let accessibilityLabel: String
        /// "restarting in 5 seconds" while a restart waits; nil otherwise.
        public let accessibilityValue: String?
        /// The drawer, while open.
        public let log: Log?
    }

    /// A row's button.
    public enum RowAction: Equatable, Sendable {
        /// Start (.play, primary) or Stop (.stop): `toggleRun(_:)`.
        case run(title: String, glyph: Glyph, isPrimary: Bool)
        /// "Edit…" (secondary), for a service from services.json that breaks a rule and can't
        /// start: `AppModel.editService(_:)`.
        case edit(title: String)
    }

    public struct Log: Equatable, Sendable {
        /// Oldest first.
        public let lines: [LogLineScreen]
        /// "No output yet. Start the service to see its logs.", when there are no lines.
        public let emptyText: String?
        public let clear: String
    }

    /// One log line: the time in --ink-3, then the text.
    public struct LogLineScreen: Equatable, Sendable, Identifiable {
        /// The line's number in the log, which stays the same as older lines drop off.
        public let id: Int
        /// "14:03:27"
        public let time: String
        public let text: String
    }
}

extension ServiceStore {
    /// The Services tab at `now`. Log times are in `timeZone`.
    public func screen(at now: Date, timeZone: TimeZone = .current) -> ServicesScreen {
        let running = snapshot.running
        return ServicesScreen(
            label: Strings.Services.tabLabel(running: running),
            note: definitions.isEmpty || loadError != nil ? nil : Strings.Services.tabNote, edit: Strings.Services.edit,
            isolationNotice: showsIsolationNotice
                ? ServicesScreen.IsolationNotice(
                    title: Strings.Services.isolationTitle, text: Strings.Services.isolationText,
                    ok: Strings.Services.ok) : nil,
            fileProblem: loadError.map { FileProblemCard($0, kind: .services) },
            empty: definitions.isEmpty && loadError == nil
                ? ServicesScreen.Empty(
                    title: Strings.Services.emptyTitle, text: Strings.Services.emptyText,
                    add: Strings.Services.addService)
                : nil,
            rows: definitions.map { row($0, now: now, timeZone: timeZone) })
    }

    /// A row's button: Stop while it runs, whatever its definition says, so Stop never goes;
    /// otherwise Start, or Edit… when it can't start.
    static func action(isLive: Bool, canStart: Bool) -> ServicesScreen.RowAction {
        if isLive { return .run(title: Strings.Services.stopVerb, glyph: .stop, isPrimary: false) }
        if !canStart { return .edit(title: Strings.Services.edit) }
        return .run(title: Strings.Services.startVerb, glyph: .play, isPrimary: true)
    }

    /// The row's Start / Stop button: one intent for either.
    public func toggleRun(_ id: ServiceDefinition.ID) {
        if state(id).isLive || isWaitingForEnvironment(id) || isWaitingToRestart(id) { stop(id) } else { start(id) }
    }

    private func row(_ definition: ServiceDefinition, now: Date, timeZone: TimeZone) -> ServicesScreen.Row {
        let state = state(definition.id)
        // Waiting for the shell's environment looks like Starting, with Stop.
        let waiting = isWaitingForEnvironment(definition.id)
        let silent = silentPorts.contains(definition.id)
        let status: ServicesScreen.Status
        var meta: String?
        var metaStyle = ServicesScreen.MetaStyle.secondary
        var spoken: String?
        switch state {
        case _ where waiting, .starting:
            status = .starting
            meta = Strings.Services.startingMeta(port: definition.port)
        case .stopped:
            status = .stopped
        case .running(_, let since, let port):
            status = .running
            if silent, let port {
                meta = Strings.Services.silentMeta(port: port)
                metaStyle = .warn
            } else {
                meta = Strings.Services.runningMeta(
                    port: port, uptime: Format.minutes(now.timeIntervalSince(since), rounding: .up))
                metaStyle = .accent
            }
        case .waitingToRestart(_, let at, let lastExit):
            // The starting ring, with Stop; the view redraws the countdown each second.
            status = .starting
            let seconds = max(1, Int(at.timeIntervalSince(now).rounded(.up)))
            meta = Strings.Services.restartingMeta(seconds: seconds, exit: Strings.Services.exitPhrase(lastExit))
            metaStyle = .warn
            spoken = Strings.Services.restartingAccessibility(seconds: seconds)
        case .failed(_, _, let since?):
            status = .failed
            var calendar = Calendar.current
            calendar.timeZone = timeZone
            meta = Strings.Services.gaveUpMeta(
                since: Format.time(since, calendar: calendar), restarts: Self.maxRestarts)
        case .failed(let code, let at, nil):
            status = .failed
            meta = Strings.Services.failedMeta(code: code, ago: Strings.Services.ago(at, now: now))
        }
        // A service that breaks a rule can only have been read from services.json; it never ran.
        let problem = state.isLive ? nil : definition.firstProblem
        if let problem {
            meta = Strings.Services.cantStart(problem)
            metaStyle = .warn
        }
        let logsOpen = openLogs == definition.id
        let lines = logLines(definition.id).map { line in
            ServicesScreen.LogLineScreen(
                id: line.id, time: LogRing.time(line.time, timeZone: timeZone), text: line.text)
        }
        return ServicesScreen.Row(
            id: definition.id, name: definition.name, status: status, meta: meta, metaStyle: metaStyle,
            commandLine: Strings.Services.actionSubtitle(command: definition.command, cwd: definition.cwd),
            keepsAwake: definition.keepAwake, restarts: definition.restartOnExit,
            logsOpen: logsOpen, logsWarning: silent && state.isLive,
            action: Self.action(
                isLive: state.isLive || waiting || isWaitingToRestart(definition.id), canStart: problem == nil),
            accessibilityLabel: Strings.Services.rowAccessibility(
                name: definition.name, status: status, keepsAwake: definition.keepAwake,
                restarts: definition.restartOnExit),
            accessibilityValue: spoken,
            log: logsOpen
                ? ServicesScreen.Log(
                    lines: lines, emptyText: lines.isEmpty ? Strings.Services.noOutput : nil,
                    clear: Strings.Services.clear) : nil)
    }
}
