import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// An AppModel with a fake launcher, a real data folder, and fake everything else.
@MainActor
private final class ServicesHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let launcher = FakeServiceLauncher()
    let probe = FakePortProbe()
    let notifier = FakeNotifier()
    let picker = FakeOpenPanels()
    let terminals = FakeTerminalLauncher()
    let revealer = FakeFileRevealer()
    let folder: URL
    let work: URL
    private let ownsRoot: Bool
    private(set) var model: AppModel!
    var services: ServiceStore { model.services }

    /// `sharing` another harness uses its data folder: a second launch over the same files.
    /// `realLauncher` starts real processes. `readsShellEnvironment` reads the login shell's environment
    /// before the first service starts, through the same launcher.
    init(
        loginShell: String = "/bin/zsh", canDisclaim: Bool = true, file: String? = nil,
        sharing other: ServicesHarness? = nil, realLauncher: Bool = false, readsShellEnvironment: Bool = false,
        environment: [String: String] = ["PATH": "/usr/bin"]
    ) throws {
        scheduler = ManualScheduler(clock: clock)
        let root =
            other?.folder.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("headsup-svcs-\(UUID().uuidString)")
        ownsRoot = other == nil
        folder = root.appendingPathComponent("HeadsUp")
        work = root.appendingPathComponent("web-app")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let file {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(file.utf8).write(to: folder.appendingPathComponent("services.json"))
        }
        launcher.canDisclaim = canDisclaim
        var settings = Settings()
        settings.general.welcomeDone = true
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(),
                files: revealer, loginItem: FakeLoginItem(), systemSettings: FakeSystemSettingsLinks(),
                notifier: notifier, powerAssertions: FakePowerAssertions(), powerSource: FakePowerSource(),
                serviceLauncher: realLauncher ? POSIXServiceLauncher() : launcher, portProbe: probe,
                openPanels: picker, imageProcessor: FakeImageProcessor(), calendar: FakeCalendarReader(),
                reminders: FakeRemindersAccess(), terminalLauncher: terminals,
                secrets: MemorySecretStore(),
                httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(), pasteboard: FakePasteboard(),
                dataFolder: folder, loginShell: loginShell,
                home: root.path, environment: environment, readsShellEnvironment: readsShellEnvironment),
            settings: settings)
        model.launch()
    }

    deinit {
        guard ownsRoot else { return }
        chmod(folder.path, 0o700)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// The data folder can be read but not written, as on a locked or full disk.
    func makeFolderReadOnly() {
        #expect(mkdir(folder.path, 0o700) == 0 || errno == EEXIST)
        #expect(chmod(folder.path, 0o500) == 0)
    }

    /// Adds a service in the work folder and returns its id.
    @discardableResult
    func add(
        _ name: String = "Web dev server", command: String = "npm run dev", port: Int? = nil,
        env: [EnvironmentVariable] = [], autostart: Bool = false, keepAwake: Bool = false,
        restartOnExit: Bool = false
    ) -> ServiceDefinition.ID {
        let definition = ServiceDefinition(
            name: name, command: command, cwd: work.path, env: env, port: port, autostart: autostart,
            keepAwake: keepAwake, restartOnExit: restartOnExit)
        #expect(services.save(definition).isEmpty)
        return definition.id
    }

    var file: URL { folder.appendingPathComponent("services.json") }
    var toast: FooterLeft { model.hud.footerLeft }
    func logText(_ id: ServiceDefinition.ID) -> [String] { services.logLines(id).map(\.text) }
    func pid(_ id: ServiceDefinition.ID) -> Int32 { services.state(id).pid ?? 0 }

    /// Lets the launcher's callbacks, which hop to the main actor, run.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
@Suite(.serialized) struct ServiceStoreTests {
    // MARK: services.json

    @Test func aFreshInstallCreatesNoFileUntilAServiceIsSaved() throws {
        let h = try ServicesHarness()
        #expect(h.services.definitions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.file.path))
        h.add()
        #expect(h.toast == .toast("Added Web dev server"))
        let mode = try FileManager.default.attributesOfItem(atPath: h.file.path)[.posixPermissions] as! NSNumber
        #expect(mode.intValue & 0o777 == 0o600)
    }

    @Test func savedServicesComeBackAtTheNextLaunch() throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000, env: [EnvironmentVariable(key: "NODE_ENV", value: "development")])
        let data = try Data(contentsOf: h.file)
        let next = try ServicesHarness(file: String(decoding: data, as: UTF8.self))
        #expect(next.services.definitions.map(\.id) == [id])
        #expect(next.services.definitions.first?.env == [EnvironmentVariable(key: "NODE_ENV", value: "development")])
    }

    @Test func aFileMissingOptionalFieldsLoadsWithDefaults() throws {
        let h = try ServicesHarness(file: #"{ "services": [ { "name": "Ollama", "command": "ollama serve" } ] }"#)
        let ollama = try #require(h.services.definitions.first)
        #expect(ollama.cwd == "~" && ollama.env.isEmpty && ollama.port == nil && !ollama.autostart)
        #expect(h.services.canEdit)
    }

    @Test func aBrokenFileIsNeverOverwrittenAndTheEditorIsOff() throws {
        let broken = #"{ "services": [ { "name": "Web", "command": "x", "port": "three thousand" } ] }"#
        let h = try ServicesHarness(file: broken)
        #expect(h.services.loadError == .unreadable(reason: "the port of service 1 isn't valid"))
        #expect(!h.services.canEdit)
        let problems = h.services.save(ServiceDefinition(name: "New", command: "y", cwd: h.work.path))
        #expect(!problems.isEmpty)
        #expect(String(decoding: try Data(contentsOf: h.file), as: UTF8.self) == broken)
    }

    @Test func theFormsRulesAndAMissingFolder() throws {
        let h = try ServicesHarness()
        let problems = h.services.save(ServiceDefinition(name: "", command: "", cwd: "/no/such/folder", port: 70_000))
        #expect(Set(problems.keys) == [.name, .command, .cwd, .port])
        #expect(problems[.cwd] == "This folder doesn't exist.")
        #expect(h.services.definitions.isEmpty)
    }

    // MARK: Start

    @Test func startRunsTheCommandThroughTheLoginShellInItsFolder() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let plan = try #require(h.launcher.launched[h.pid(id)])
        #expect(plan.arguments == ["/bin/zsh", "-l", "-c", "npm run dev"])
        #expect(plan.directory == h.work.path)
        #expect(h.logText(id) == ["$ npm run dev", "starting…"])
        #expect(h.toast == .toast("Started Web dev server"))
        guard case .starting = h.services.state(id) else {
            Issue.record("expected starting")
            return
        }
        h.scheduler.advance(by: 3)
        #expect(h.services.state(id) == .running(pid: h.pid(id), since: h.clock.now.addingTimeInterval(-3), port: nil))
    }

    @Test func environmentValuesNeverReachTheLog() async throws {
        let h = try ServicesHarness()
        let id = h.add(command: "npm run dev", env: [EnvironmentVariable(key: "API_TOKEN", value: "sk-very-secret")])
        h.services.start(id)
        h.launcher.emit(h.pid(id), "ready\n")
        await h.settle()
        h.scheduler.advance(by: 0.1)
        let plan = try #require(h.launcher.launched[h.pid(id)])
        #expect(plan.environment.contains("API_TOKEN=sk-very-secret"))
        #expect(h.logText(id).allSatisfy { !$0.contains("sk-very-secret") && !$0.contains("API_TOKEN") })
        #expect(h.logText(id).last == "ready")
    }

    @Test func outputReachesTheLogAtMostEveryTenthOfASecond() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.launcher.emit(h.pid(id), "Listening on ")
        h.launcher.emit(h.pid(id), ":3000\n")
        await h.settle()
        #expect(h.logText(id).count == 2)
        h.scheduler.advance(by: 0.1)
        #expect(h.logText(id).last == "Listening on :3000")
    }

    @Test func fishAsTheLoginShellRunsInZshAndSaysSo() throws {
        let h = try ServicesHarness(loginShell: "/opt/homebrew/bin/fish")
        let id = h.add()
        h.services.start(id)
        #expect(h.launcher.launched[h.pid(id)]?.executable == "/bin/zsh")
        #expect(h.logText(id).contains("fish isn't supported for services; running in zsh"))
    }

    @Test func withoutTheDisclaimServicesStartAnywayWithTheWarning() throws {
        let h = try ServicesHarness(canDisclaim: false)
        #expect(h.services.isolationWarning)
        #expect(h.services.showsIsolationNotice)
        let id = h.add()
        h.services.start(id)
        #expect(h.services.state(id).isLive)
        #expect(h.logText(id).contains("started without separate permissions (macOS limitation)"))
        h.services.dismissIsolationNotice()
        #expect(!h.services.showsIsolationNotice)
        #expect(h.services.isolationWarning)
    }

    @Test func autostartServicesStartAtLaunch() throws {
        let h = try ServicesHarness()
        let id = h.add(autostart: true)
        let data = try Data(contentsOf: h.file)
        let next = try ServicesHarness(file: String(decoding: data, as: UTF8.self))
        #expect(next.services.state(id).isLive)
    }

    @Test func theProbedPortMarksItRunning() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.probe.port = 5173
        h.services.start(id)
        h.scheduler.advance(by: 2)
        await h.settle()
        #expect(h.services.state(id) == .running(pid: h.pid(id), since: h.clock.now.addingTimeInterval(-2), port: 5173))
    }

    // MARK: Stop, failure, restart

    @Test func stopSendsSIGTERMToTheGroupThenSIGKILL() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        h.services.stop(id)
        #expect(h.launcher.signals.last! == (pid, SIGTERM))
        #expect(h.toast == .toast("Stopped Web dev server"))
        h.scheduler.advance(by: 3)
        #expect(h.launcher.signals.last! == (pid, SIGKILL))
        h.launcher.finish(pid, .signal(SIGKILL))
        await h.settle()
        #expect(h.services.state(id) == .stopped)
        #expect(h.logText(id).last == "process exited (SIGKILL)")
        #expect(!h.services.failureUnseen)
        #expect(h.notifier.pending.isEmpty)
    }

    // Scan M1: children that ignore SIGTERM outlive their leader, so the SIGKILL always goes.
    // The leader is reaped only after it, so the group id is still the service's.
    @Test func stopSendsSIGKILLEvenWhenTheLeaderHasExitedAndReapsAfterIt() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        h.services.stop(id)
        h.launcher.finish(pid, .signal(SIGTERM))
        await h.settle()
        #expect(h.services.state(id) == .stopped)
        #expect(h.logText(id).last == "process exited (SIGTERM)")
        #expect(h.launcher.events == ["TERM \(pid)"])
        h.scheduler.advance(by: 3)
        #expect(h.launcher.events == ["TERM \(pid)", "KILL \(pid)", "reap \(pid)"])
    }

    @Test func aLeaderStillThereAtTheSIGKILLIsReapedWhenItExits() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        h.services.stop(id)
        h.scheduler.advance(by: 3)
        h.launcher.finish(pid, .signal(SIGKILL))
        await h.settle()
        #expect(h.launcher.events == ["TERM \(pid)", "KILL \(pid)", "reap \(pid)"])
    }

    @Test func anExitNobodyAskedForIsReapedAtOnce() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        h.launcher.finish(pid, .code(1))
        await h.settle()
        #expect(h.launcher.events == ["reap \(pid)"])
    }

    @Test func quittingSendsSIGKILLToEveryGroupAfterItsLeaderExits() async throws {
        let h = try ServicesHarness()
        let a = h.add("A")
        let b = h.add("B")
        h.services.start(a)
        h.services.start(b)
        let (pa, pb) = (h.pid(a), h.pid(b))
        let quitting = Task { await h.services.stopAll() }
        await h.settle()
        h.launcher.finish(pa, .signal(SIGTERM))
        h.launcher.finish(pb, .signal(SIGTERM))
        await quitting.value
        let events = h.launcher.events
        for pid in [pa, pb] {
            let kill = try #require(events.firstIndex(of: "KILL \(pid)"))
            let reap = try #require(events.firstIndex(of: "reap \(pid)"))
            #expect(events.firstIndex(of: "TERM \(pid)")! < kill && kill < reap)
        }
    }

    @Test func anExitOnItsOwnIsAFailureWithANotificationAndTheRedDot() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.scheduler.advance(by: 3)
        h.launcher.finish(h.pid(id), .code(1))
        await h.settle()
        #expect(h.services.state(id) == .failed(exitCode: 1, at: h.clock.now))
        #expect(h.logText(id).last == "process exited (code 1)")
        let request = try #require(h.notifier.pending["service.failed:\(id)"])
        #expect(request.category == .serviceFailed)
        #expect(request.title == "Web dev server stopped")
        #expect(request.body == "It exited with code 1.")
        #expect(h.model.tabActivity[.services] == .alert)
        #expect(h.services.openLogs == nil)  // a crash later doesn't open the logs
        h.model.hud.selectTab(.services)
        #expect(h.model.tabActivity[.services] == nil)
    }

    @Test func failingToStartOpensTheLogs() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.launcher.finish(h.pid(id), .code(127))
        await h.settle()
        #expect(h.services.openLogs == id)
    }

    @Test func aLaunchErrorIsLoggedAndFails() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.launcher.failNextLaunch = LaunchError(operation: "posix_spawn /bin/zsh", code: ENOENT)
        h.services.start(id)
        guard case .failed = h.services.state(id) else {
            Issue.record("expected failed")
            return
        }
        #expect(h.logText(id).last?.hasPrefix("couldn't start: posix_spawn /bin/zsh") == true)
        #expect(h.services.openLogs == id)
    }

    @Test func restartStopsThenStartsAgain() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let first = h.pid(id)
        h.services.restart(id)
        h.launcher.finish(first, .signal(SIGTERM))
        await h.settle()
        #expect(h.services.state(id).isLive)
        #expect(h.pid(id) != first)
    }

    @Test func removingARunningServiceStopsIt() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.services.delete(id)
        #expect(h.launcher.signals.last?.signal == SIGTERM)
        #expect(h.services.definitions.isEmpty)
        #expect(h.toast == .toast("Removed Web dev server"))
    }

    // MARK: The rest of the app

    @Test func theMenuRowCountsRunningStartingAndFailed() async throws {
        let h = try ServicesHarness()
        #expect(Strings.MenuBar.services(h.services.snapshot) == "None")
        let a = h.add("A")
        let b = h.add("B")
        let c = h.add("C")
        h.services.start(a)
        h.services.start(b)
        h.scheduler.advance(by: 3)
        h.services.start(c)
        h.launcher.finish(h.pid(b), .code(2))
        await h.settle()
        #expect(Strings.MenuBar.services(h.services.snapshot) == "1 running · 1 starting · 1 failed")
    }

    @Test func quittingAsksOnlyWhileServicesRun() throws {
        let h = try ServicesHarness()
        #expect(h.model.quitQuestion == nil)
        h.model.caffeine.toggle()
        #expect(h.model.quitQuestion == nil)  // Caffeine alone doesn't ask
        let postgres = h.add("Postgres")
        h.services.start(postgres)
        #expect(h.model.quitQuestion?.title == "1 service is running")
        #expect(h.model.quitQuestion?.message == "If you quit HeadsUp, Postgres will be terminated.")
        #expect(h.model.quitQuestion?.detail == "Your focus timer and Caffeine also stop.")
        let ollama = h.add("Ollama")
        h.services.start(ollama)
        #expect(h.model.quitQuestion?.title == "2 services are running")
        #expect(h.model.quitQuestion?.message == "If you quit HeadsUp, Postgres and Ollama will be terminated.")
        #expect(h.model.quitQuestion?.quit == "Quit and Terminate")
        #expect(h.model.quitQuestion?.cancel == "Cancel")
        #expect(
            Strings.Services.quitMessage(["a", "b", "c"]) == "If you quit HeadsUp, a, b and c will be terminated.")
        #expect(Strings.Services.quitTitle(3) == "3 services are running")
    }

    @Test func showLogsFromTheNotificationOpensServicesWithThatLog() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.model.handleNotification(category: "service.failed", action: "show-logs", requestID: "service.failed:\(id)")
        #expect(h.model.hud.tab == .services && h.model.hud.isOpen)
        #expect(h.services.openLogs == id)
        h.model.handleNotification(category: "service.failed", action: "start-break", requestID: "service.failed:\(id)")
        h.model.handleNotification(category: "service.failed", action: nil, requestID: "service.failed:nope")
        #expect(h.services.openLogs == id)
    }

    @Test func theActionsFollowEachServicesState() throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        let start = try #require(h.model.registry.actions.first { $0.id == ActionID("service.start:\(id)") })
        #expect(start.title == "Start Web dev server")
        #expect(start.subtitle == "npm run dev · \(h.work.path)")
        #expect(
            start.suggest
                == .confirm(
                    Confirmation(verb: "Start", name: "Web dev server", command: "npm run dev", cwd: h.work.path)))
        start.run()
        let ids = h.model.registry.actions.map(\.id.rawValue)
        #expect(ids.contains("service.stop:\(id)") && ids.contains("service.restart:\(id)"))
        #expect(!ids.contains("service.start:\(id)"))
        h.model.hud.setInput("ssh")  // matching the command line through keywords
        h.model.hud.setInput("npm")
        #expect(h.model.hud.suggestions.contains { $0.title == "Stop Web dev server" })
    }
}

@MainActor
@Suite(.serialized) struct ServicesScreenTests {
    static let start = ServicesScreen.RowAction.run(title: "Start", glyph: .play, isPrimary: true)

    @Test func anEmptyTabOffersToAddOne() throws {
        let h = try ServicesHarness()
        let screen = h.services.screen(at: h.clock.now)
        #expect(screen.label == "Services · 0 running")
        #expect(screen.empty?.title == "No services yet")
        #expect(screen.rows.isEmpty)
        #expect(screen.isolationNotice == nil)
    }

    @Test func eachStateReadsAsDesigned() async throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        var row = h.services.screen(at: h.clock.now).rows[0]
        #expect(row.status == .stopped && row.meta == nil && row.action == Self.start)
        #expect(row.accessibilityLabel == "Web dev server, stopped")
        #expect(row.commandLine == "npm run dev · \(h.work.path)")

        #expect(row.action == .run(title: "Start", glyph: .play, isPrimary: true))

        h.services.toggleRun(id)
        row = h.services.screen(at: h.clock.now).rows[0]
        #expect(row.status == .starting && row.meta == "Starting… waiting for :3000" && row.metaStyle == .secondary)
        #expect(row.action == .run(title: "Stop", glyph: .stop, isPrimary: false))

        h.probe.answering = [3000]
        h.scheduler.advance(by: 42 * 60)
        await h.settle()
        row = h.services.screen(at: h.clock.now).rows[0]
        #expect(row.status == .running && row.meta == ":3000 · 42m" && row.metaStyle == .accent)
        #expect(!row.logsWarning)

        h.launcher.finish(h.pid(id), .code(1))
        await h.settle()
        row = h.services.screen(at: h.clock.now.addingTimeInterval(120)).rows[0]
        #expect(row.status == .failed && row.meta == "Exited with code 1 · 2 min ago" && row.action == Self.start)
        #expect(row.accessibilityLabel == "Web dev server, failed")
    }

    @Test func theDrawerShowsTimedLinesOrItsEmptyText() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.toggleLogs(id)
        #expect(
            h.services.screen(at: h.clock.now).rows[0].log?.emptyText
                == "No output yet. Start the service to see its logs.")
        h.services.start(id)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let log = try #require(h.services.screen(at: h.clock.now, timeZone: utc).rows[0].log)
        #expect(log.lines.map(\.text) == ["$ npm run dev", "starting…"])
        #expect(log.lines.map(\.id) == [0, 1])
        #expect(log.lines[0].time == LogRing.time(h.clock.now, timeZone: utc) && log.lines[0].time.count == 8)
        #expect(log.emptyText == nil && log.clear == "Clear")
        h.services.clearLogs(id)
        #expect(h.services.screen(at: h.clock.now).rows[0].log?.lines.isEmpty == true)
        h.services.toggleLogs(id)
        #expect(h.services.screen(at: h.clock.now).rows[0].log == nil)
    }

    @Test func theIsolationNoticeShowsUntilDismissed() throws {
        let h = try ServicesHarness(canDisclaim: false)
        let notice = try #require(h.services.screen(at: h.clock.now).isolationNotice)
        #expect(notice.title == "Services run with HeadsUp's permissions on this version of macOS.")
        h.services.dismissIsolationNotice()
        #expect(h.services.screen(at: h.clock.now).isolationNotice == nil)
    }
}

/// Nick's regression tests (msg-406): a removed service counts nowhere.
@MainActor
@Suite(.serialized) struct ServiceDeleteTests {
    @Test func aRemovedFailedServiceNoLongerCountsAsFailed() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.launcher.finish(h.pid(id), .code(1))
        await h.settle()
        h.services.delete(id)
        #expect(h.services.snapshot.failed == 0)
        #expect(h.services.logLines(id).isEmpty)
        #expect(Strings.MenuBar.services(h.services.snapshot) == "None")
    }

    @Test func aServiceRemovedWhileRunningLeavesNothingOnceItExits() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        h.services.delete(id)
        #expect(h.services.snapshot.starting == 1)  // still there until it has exited
        h.launcher.finish(pid, .signal(SIGTERM))
        await h.settle()
        #expect(h.services.snapshot == ServicesSnapshot())
        #expect(h.services.state(id) == .stopped)
        #expect(h.services.logLines(id).isEmpty)
        #expect(h.notifier.pending.isEmpty)
    }

    @Test func savingWhileTheFileCantBeReadNamesTheFile() throws {
        let h = try ServicesHarness(file: "not json")
        let problems = h.services.save(ServiceDefinition(name: "New", command: "y", cwd: h.work.path))
        #expect(problems == [.file: "You can't change services until `services.json` can be read."])
    }
}

/// Rev 1: a save or a remove that can't be written changes nothing, and says why in the form.
@MainActor
@Suite(.serialized) struct ServiceFileFailureTests {
    @Test func aSaveThatCantBeWrittenKeepsTheListOnDisk() throws {
        let h = try ServicesHarness()
        let web = h.add()
        h.makeFolderReadOnly()
        let problems = h.services.save(ServiceDefinition(name: "Postgres", command: "postgres", cwd: h.work.path))
        #expect(problems == [.file: "Couldn't save: HeadsUp isn't allowed to write to its settings folder."])
        #expect(h.toast != .toast("Added Postgres"))
        #expect(h.services.definitions.map(\.id) == [web])
        let next = try ServicesHarness(sharing: h)
        #expect(next.services.definitions.map(\.id) == [web])
    }

    @Test func aRemoveThatCantBeWrittenKeepsTheServiceAndItsProcess() throws {
        let h = try ServicesHarness()
        let web = h.add()
        h.services.start(web)
        h.makeFolderReadOnly()
        let problems = h.services.delete(web)
        #expect(problems[.file]?.hasPrefix("Couldn't save: ") == true)
        #expect(h.toast != .toast("Removed Web dev server"))
        #expect(h.services.definitions.map(\.id) == [web])
        #expect(h.services.state(web).isLive && h.launcher.signals.isEmpty)
        #expect(try ServicesHarness(sharing: h).services.definitions.map(\.id) == [web])
    }

    @Test func theFormStaysOpenWithTheReasonInItsBar() throws {
        let h = try ServicesHarness()
        h.model.addService()
        h.services.updateDraft {
            $0.name = "Web"
            $0.command = "npm run dev"
            $0.cwd = h.work.path
        }
        h.makeFolderReadOnly()
        h.services.saveForm()
        let form = try #require(h.services.settingsScreen.form)
        #expect(form.saveProblem == "Couldn't save: HeadsUp isn't allowed to write to its settings folder.")
        #expect(form.problems.isEmpty && form.saveEnabled)
        #expect(h.services.definitions.isEmpty)
        chmod(h.folder.path, 0o700)
        h.services.saveForm()
        #expect(h.services.form == nil && h.services.definitions.count == 1)
        #expect(h.toast == .toast("Added Web"))
    }
}

/// Scan M1's proof (tools/proofs/stop-leaves-children.sh) as a regression test, with real
/// processes: a child that ignores SIGTERM is gone after Stop, or after quitting.
@MainActor
@Suite(.serialized) struct ServiceStopRegressionTests {
    static let stubborn = #"sh -c 'trap "" TERM; exec sleep 30' & wait"#

    /// Whether no process is left in the group: `kill(-group, 0)` fails with ESRCH. Our Linux
    /// sandbox's PID 1 doesn't reap orphans, so there a group of zombies only counts as gone.
    private func groupIsGone(_ group: Int32) -> Bool {
        if kill(-group, 0) == -1 && errno == ESRCH { return true }
        #if canImport(Glibc)
            let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc"))?.compactMap { Int32($0) } ?? []
            return !pids.contains { pid in
                // "pid (command) state ppid pgrp …"
                guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                    let close = stat.lastIndex(of: ")")
                else { return false }
                let fields = stat[stat.index(after: close)...].split(separator: " ")
                return fields.count > 2 && fields[0] != "Z" && Int32(fields[2]) == group
            }
        #else
            return false
        #endif
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func stopLeavesNoChildThatIgnoresSIGTERM() async throws {
        let h = try ServicesHarness(loginShell: "/bin/sh", realLauncher: true)
        let id = h.add(command: Self.stubborn)
        h.services.start(id)
        let group = h.pid(id)
        try await Task.sleep(nanoseconds: 300_000_000)  // the child starts and ignores TERM
        h.services.stop(id)
        #expect(await waitUntil(3) { h.services.state(id) == .stopped })
        #expect(!groupIsGone(group))  // the leader went; the child is still there
        h.scheduler.advance(by: 3)
        #expect(await waitUntil(2) { groupIsGone(group) })
    }

    @Test func quittingLeavesNoChildThatIgnoresSIGTERM() async throws {
        let h = try ServicesHarness(loginShell: "/bin/sh", realLauncher: true)
        let id = h.add(command: Self.stubborn)
        h.services.start(id)
        let group = h.pid(id)
        try await Task.sleep(nanoseconds: 300_000_000)
        await h.services.stopAll()
        #expect(await waitUntil(2) { groupIsGone(group) })
    }
}

/// Rev 3 / Scan L1: a launch macOS refused to disclaim is not isolated.
@MainActor
@Suite(.serialized) struct ServiceIsolationTests {
    @Test func aRefusedDisclaimStartsTheServiceWithTheWarning() throws {
        let h = try ServicesHarness()
        #expect(!h.services.isolationWarning)
        h.launcher.refuseDisclaim = true
        let id = h.add()
        h.services.start(id)
        #expect(h.services.state(id).isLive)
        #expect(h.logText(id).contains("started without separate permissions (macOS limitation)"))
        #expect(h.services.isolationWarning && h.services.showsIsolationNotice)
    }

    @Test func anIsolatedLaunchLogsNoWarning() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        #expect(!h.logText(id).contains { $0.hasPrefix("started without") })
        #expect(!h.services.isolationWarning)
    }
}

/// Scan L2: services.json is checked at load, since it can be edited by hand.
@MainActor
@Suite(.serialized) struct ServiceLoadValidationTests {
    static let file = #"""
        { "services": [
          { "id": "a", "name": "Empty", "command": "  ", "autostart": true },
          { "id": "b", "name": "Nul", "command": "echo hi\u0000rm -rf ~" },
          { "id": "c", "name": "Fine", "command": "npm run dev" }
        ] }
        """#

    @Test func aServiceThatBreaksARuleCantStartAndSaysWhy() throws {
        let h = try ServicesHarness(file: Self.file)
        #expect(h.services.definitions.count == 3 && h.services.canEdit)
        #expect(h.launcher.launched.isEmpty)  // autostart skips it
        for id in ["a", "b"] {
            h.services.start(id)
            #expect(h.services.state(id) == .stopped)
        }
        #expect(h.launcher.launched.isEmpty)
        let rows = h.services.screen(at: h.clock.now).rows
        #expect(rows[0].meta == "Can't start · enter a command to run" && rows[0].metaStyle == .warn)
        #expect(rows[1].meta == "Can't start · this has a hidden character that can't be used. Type it again")
        #expect(rows[0].action == .edit(title: "Edit…") && rows[1].action == .edit(title: "Edit…"))
        #expect(rows[2].action == .run(title: "Start", glyph: .play, isPrimary: true) && rows[2].meta == nil)
        let ids = h.model.registry.actions.map(\.id.rawValue)
        #expect(!ids.contains("service.start:a") && !ids.contains("service.start:b"))
        #expect(ids.contains("service.start:c"))
    }

    @Test func fixingItInTheFormLetsItStart() throws {
        let h = try ServicesHarness(file: Self.file)
        h.services.editService("a")
        h.services.updateDraft {
            $0.command = "ollama serve"
            $0.cwd = h.work.path
        }
        h.services.saveForm()
        #expect(h.services.form == nil)
        h.services.start("a")
        #expect(h.services.state("a").isLive)
    }
}

/// Rev 2 and Yuki's rule: a service with a port set is starting until the port answers.
@MainActor
@Suite(.serialized) struct ServicePortTests {
    @Test func itIsRunningOnceItsPortAnswers() async throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        h.services.start(id)
        let pid = h.pid(id)
        h.scheduler.advance(by: 1)
        await h.settle()
        #expect(h.services.state(id) == .starting(pid: pid, since: h.clock.now.addingTimeInterval(-1)))
        h.probe.answering = [3000]
        h.scheduler.advance(by: 1)
        await h.settle()
        #expect(h.services.state(id) == .running(pid: pid, since: h.clock.now.addingTimeInterval(-2), port: 3000))
    }

    @Test func aSilentPortIsNeverRunningAtThreeSeconds() async throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        h.services.start(id)
        for _ in 0..<29 {
            h.scheduler.advance(by: 1)
            await h.settle()
        }
        guard case .starting = h.services.state(id) else {
            Issue.record("expected starting at 29 s, got \(h.services.state(id))")
            return
        }
        #expect(h.services.screen(at: h.clock.now).rows[0].meta == "Starting… waiting for :3000")
    }

    @Test func afterThirtySecondsAliveItRunsWithAWarningUntilThePortAnswers() async throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        h.services.start(id)
        for _ in 0..<30 {
            h.scheduler.advance(by: 1)
            await h.settle()
        }
        #expect(h.services.snapshot.running == 1)
        var row = h.services.screen(at: h.clock.now).rows[0]
        #expect(row.status == .running && row.meta == "Running · nothing on :3000 yet")
        #expect(
            row.metaStyle == .warn && row.logsWarning
                && row.action == .run(title: "Stop", glyph: .stop, isPrimary: false))

        h.probe.answering = [3000]
        h.scheduler.advance(by: 5)
        await h.settle()
        row = h.services.screen(at: h.clock.now).rows[0]
        #expect(row.meta == ":3000 · 1m" && row.metaStyle == .accent && !row.logsWarning)
    }

    @Test func noPortIsTriedOnceItHasStopped() async throws {
        let h = try ServicesHarness()
        let id = h.add(port: 3000)
        h.services.start(id)
        h.launcher.finish(h.pid(id), .code(1))
        await h.settle()
        h.probe.answering = [3000]
        h.scheduler.advance(by: 60)
        await h.settle()
        #expect(h.services.state(id) == .failed(exitCode: 1, at: h.clock.now.addingTimeInterval(-60)))
    }
}

/// Yuki's final Services copy.
@MainActor
@Suite(.serialized) struct ServiceCopyTests {
    @Test func relativeTimes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let us = Locale(identifier: "en_US")
        func ago(_ seconds: TimeInterval) -> String {
            Strings.Services.ago(now.addingTimeInterval(-seconds), now: now, locale: us, timeZone: utc)
        }
        #expect(ago(30) == "just now")
        #expect(ago(60) == "1 min ago" && ago(12 * 60) == "12 min ago")
        #expect(ago(3600) == "1 h ago" && ago(5 * 3600 + 59) == "5 h ago")
        #expect(ago(24 * 3600) == "yesterday" && ago(47 * 3600) == "yesterday")
        // 1_800_000_000 is Jan 15, 2027 08:00 UTC.
        #expect(ago(48 * 3600) == "Jan 13")
    }

    @Test func theTabsEmptyStateHasTheLongCopy() throws {
        let h = try ServicesHarness()
        let empty = try #require(h.services.screen(at: h.clock.now).empty)
        #expect(empty.text == "Add a dev server, a database or a local model, then start and stop it here.")
        #expect(empty.add == "Add a service…")
        #expect(h.services.settingsScreen.emptyCard == "No services yet. Add one to start and stop it from the HUD.")
    }

    @Test func theFormsProblems() throws {
        let h = try ServicesHarness()
        h.services.editService(nil)
        h.services.updateDraft {
            $0.name = String(repeating: "a", count: 65)
            $0.port = "three thousand"
            $0.env = [EnvironmentVariable(key: "1X", value: "")]
        }
        h.services.saveForm()
        let problems = try #require(h.services.settingsScreen.form?.problems)
        #expect(problems[.name] == "Use 64 characters or fewer.")
        #expect(problems[.command] == "Enter a command to run.")
        #expect(problems[.port] == "Enter a port from 1 to 65535, or leave it empty.")
        #expect(problems[.env] == "Use only letters, digits and _, and don't start with a digit.")
        h.services.updateDraft { $0.name = " " }
        h.services.saveForm()
        #expect(h.services.settingsScreen.form?.problems[.name] == "Enter a name.")
    }
}

/// The services.json problem card, Show in Finder and Try Again.
@MainActor
@Suite(.serialized) struct ServiceFileProblemTests {
    @Test func eachReasonIsShortAndPlain() throws {
        #expect(try ServicesHarness(file: "{ nope").services.loadError == .unreadable(reason: "it isn't valid JSON"))
        let missing = try ServicesHarness(file: #"{ "services": [ { "command": "x" } ] }"#)
        #expect(missing.services.loadError == .unreadable(reason: "service 1 has no name"))
        let folder = try ServicesHarness(
            file: #"{ "services": [ { "name": "a", "command": "x" }, { "name": "b", "command": "x", "cwd": 3 } ] }"#)
        #expect(folder.services.loadError == .unreadable(reason: "the folder of service 2 isn't valid"))
    }

    @Test func theCardTakesThePlaceOfTheListAndTheEditorIsOff() throws {
        let h = try ServicesHarness(file: "{ nope")
        let screen = h.services.screen(at: h.clock.now)
        let card = try #require(screen.fileProblem)
        #expect(card.title == "Your services couldn't be loaded")
        #expect(
            card.text
                == "HeadsUp couldn't read `services.json` (it isn't valid JSON), so it left the file as it is. Fix it, then try again."
        )
        #expect(card.showInFinder == "Show in Finder" && card.tryAgain == "Try Again")
        #expect(screen.empty == nil && screen.rows.isEmpty)
        let settings = h.services.settingsScreen
        #expect(settings.fileProblem == card && !settings.addEnabled && settings.emptyCard == nil)
        h.services.editService(nil)
        #expect(h.services.form == nil)
    }

    @Test func aFileFromANewerVersionHasNoTryAgain() throws {
        let h = try ServicesHarness(file: #"{ "version": 2, "services": [] }"#)
        let card = try #require(h.services.screen(at: h.clock.now).fileProblem)
        #expect(card.title == "These services are from a newer version of HeadsUp")
        #expect(card.text == "HeadsUp left `services.json` as it is, so the newer version keeps them.")
        #expect(card.tryAgain == nil)
    }

    @Test func showInFinderAndTryAgain() throws {
        let h = try ServicesHarness(file: "{ nope")
        h.services.revealServicesFile()
        #expect(h.revealer.revealed == [h.file])
        try Data(#"{ "services": [ { "id": "w", "name": "Web", "command": "npm run dev" } ] }"#.utf8).write(to: h.file)
        h.services.reloadServices()
        #expect(h.services.loadError == nil && h.services.definitions.map(\.id) == ["w"])
        // Only while there is a problem: otherwise the list in memory is the truth.
        try Data("{ nope".utf8).write(to: h.file)
        h.services.reloadServices()
        #expect(h.services.loadError == nil && h.services.definitions.count == 1)
    }
}

/// Nick's editor contract (msg-443): the form's state, intents and screens.
@MainActor
@Suite(.serialized) struct ServiceFormTests {
    private func fill(_ h: ServicesHarness) {
        h.services.updateDraft {
            $0.name = "Web dev server"
            $0.command = "npm run dev"
            $0.cwd = h.work.path
            $0.port = "3000"
        }
    }

    @Test func addingAService() throws {
        let h = try ServicesHarness()
        h.model.addService()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .services)
        var form = try #require(h.services.settingsScreen.form)
        #expect(form.title == "New service" && form.remove == nil && form.cwd == "~" && form.port == "")
        #expect(form.runningNote == nil && form.bar == .none)
        fill(h)
        h.services.saveForm()
        #expect(h.services.form == nil)
        let saved = try #require(h.services.definitions.first)
        #expect(saved.port == 3000 && saved.cwd == h.work.path)
        #expect(h.services.settingsScreen.rows.map(\.name) == ["Web dev server"])

        h.services.editService(saved.id)
        form = try #require(h.services.settingsScreen.form)
        #expect(form.title == "Web dev server" && form.remove == "Remove…" && form.port == "3000")
    }

    @Test func anEditedFieldLosesItsProblem() throws {
        let h = try ServicesHarness()
        h.services.editService(nil)
        h.services.saveForm()
        #expect(h.services.form?.problems.keys.contains(.name) == true)
        h.services.updateDraft { $0.name = "Web" }
        #expect(h.services.form?.problems[.name] == nil && h.services.form?.problems[.command] != nil)
    }

    @Test func cancelAsksOnlyWhenThereAreChanges() throws {
        let h = try ServicesHarness()
        h.services.editService(nil)
        h.services.cancelForm()
        #expect(h.services.form == nil)

        h.services.editService(nil)
        h.services.updateDraft { $0.name = "W" }
        h.services.cancelForm()
        #expect(
            h.services.settingsScreen.form?.bar
                == .discard(question: "Discard your changes?", keep: "Keep editing", discard: "Discard"))
        h.services.dismissBar()
        #expect(h.services.form?.bar == ServiceForm.Bar.none && h.services.form?.draft.name == "W")
        h.services.cancelForm()
        h.services.discardForm()
        #expect(h.services.form == nil)
    }

    @Test func escIsTheFormsCancelWhileItShows() throws {
        let h = try ServicesHarness()
        h.model.addService()
        h.services.updateDraft { $0.name = "W" }
        h.model.escape()
        #expect(h.services.form?.bar == .discard && h.model.hud.isOpen)
        h.model.escape()  // closes the bar
        #expect(h.services.form?.bar == ServiceForm.Bar.none)
        h.model.hud.showSettings(.general)
        h.model.escape()  // not on Services: the HUD's own Esc
        #expect(!h.model.hud.isOpen && h.services.form?.draft.name == "W")
    }

    @Test func theDraftSurvivesLeavingAndAddServiceKeepsIt() throws {
        let h = try ServicesHarness()
        h.model.addService()
        h.services.updateDraft { $0.command = "ollama serve" }
        h.model.hud.selectTab(.chat)
        h.model.hud.close()
        h.model.addService()
        #expect(h.services.form?.draft.command == "ollama serve")
    }

    @Test func removingFromTheForm() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        h.services.editService(id)
        #expect(
            h.services.settingsScreen.form?.runningNote
                == "Changes to the command, folder or environment apply the next time it starts.")
        h.services.askRemove()
        #expect(
            h.services.settingsScreen.form?.bar
                == .remove(
                    question: "Web dev server is running. Removing it stops it.", cancel: "Cancel", remove: "Remove"))
        h.services.confirmRemove()
        #expect(h.services.form == nil && h.services.definitions.isEmpty)
        #expect(h.launcher.signals.last?.signal == SIGTERM)
    }

    @Test func chooseFolderWritesItIntoTheDraftUnderTheHomeFolder() async throws {
        let h = try ServicesHarness()
        h.model.addService()
        let home = h.folder.deletingLastPathComponent().path
        h.picker.answer = home + "/code/web-app"
        await h.model.chooseServiceFolder().value
        #expect(h.picker.openedAt == [home])
        #expect(h.services.form?.draft.cwd == "~/code/web-app")
        h.picker.answer = nil
        await h.model.chooseServiceFolder().value
        #expect(h.services.form?.draft.cwd == "~/code/web-app")
        h.picker.answer = "/srv/app"
        await h.model.chooseServiceFolder().value
        #expect(h.services.form?.draft.cwd == "/srv/app")
    }

    @Test func theServicesTabHasItsOwnBody() throws {
        let h = try ServicesHarness()
        h.model.hud.selectTab(.services)
        #expect(h.model.body == .services)
    }
}

/// The slice 5 fix loop's second round: log ids, Edit… on a row that can't start, the lasting
/// isolation line, and the lines that come and go with the file's state.
@MainActor
@Suite(.serialized) struct ServicesScreenRoundTwoTests {
    // Nick msg-471: ids that stay with their line, so the drawer doesn't redraw every row.
    @Test func linesKeepTheirIdsAsOlderOnesDropOff() {
        var ring = LogRing(capacity: 40)
        let t = Date(timeIntervalSince1970: 0)
        for index in 0..<10 { ring.appendLine("line \(index)", at: t) }
        let before = ring.lines
        ring.appendLine("line 10", at: t)
        #expect(ring.lines.last?.id == 10)
        for line in ring.lines.dropLast() {
            #expect(before.first { $0.text == line.text }?.id == line.id)
        }
        ring.clear()
        ring.appendLine("after clear", at: t)
        #expect(ring.lines.map(\.id) == [11])
    }

    @Test func theDrawerUsesTheLinesOwnIds() async throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.toggleLogs(id)
        h.services.start(id)  // "$ npm run dev" is 0, "starting…" is 1
        h.services.clearLogs(id)
        h.launcher.finish(h.pid(id), .code(1))
        await h.settle()
        let log = try #require(h.services.screen(at: h.clock.now).rows[0].log)
        #expect(log.lines.map(\.id) == [2] && log.lines[0].text == "process exited (code 1)")
    }

    @Test func editOnARowThatCantStartOpensTheFormWithItsProblem() throws {
        let h = try ServicesHarness(file: #"{ "services": [ { "id": "a", "name": "Empty", "command": " " } ] }"#)
        #expect(h.services.screen(at: h.clock.now).rows[0].action == .edit(title: "Edit…"))
        h.model.editService("a")
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .services)
        #expect(h.services.settingsScreen.form?.problems[.command] == "Enter a command to run.")
    }

    @Test func editServiceKeepsADraftWithChanges() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.model.addService()
        h.services.updateDraft { $0.name = "Typed" }
        h.model.editService(id)
        #expect(h.services.form?.editing == nil && h.services.form?.draft.name == "Typed")
    }

    // Rev, blocking: the disclosure lasts in Settings after the tab's notice is dismissed.
    @Test func theIsolationLineStaysAfterTheNoticeIsDismissed() throws {
        let h = try ServicesHarness(canDisclaim: false)
        h.services.dismissIsolationNotice()
        #expect(h.services.screen(at: h.clock.now).isolationNotice == nil)
        #expect(
            h.services.settingsScreen.isolationLine
                == "Services run with HeadsUp's permissions on this version of macOS.")
        #expect(try ServicesHarness().services.settingsScreen.isolationLine == nil)
    }

    @Test func theCantEditLineShowsWhileTheFileIsBroken() throws {
        #expect(
            try ServicesHarness(file: "{ nope").services.settingsScreen.cantEditLine
                == "You can't change services until `services.json` can be read.")
        #expect(try ServicesHarness().services.settingsScreen.cantEditLine == nil)
    }

    @Test func theNoteShowsOnlyWithAList() throws {
        let h = try ServicesHarness()
        #expect(h.services.screen(at: h.clock.now).note == nil)
        h.add()
        #expect(h.services.screen(at: h.clock.now).note == "Logs are always recorded, hidden until you open them")
        #expect(try ServicesHarness(file: "{ nope").services.screen(at: h.clock.now).note == nil)
    }

    @Test func theHeadersEditOpensServicesSettings() throws {
        let h = try ServicesHarness()
        #expect(h.services.screen(at: h.clock.now).edit == "Edit…")
        h.model.openServicesSettings()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .services)
    }
}

/// Nick msg-510: Stop never goes from a live row, even if its definition broke a rule.
@MainActor
@Suite struct ServiceRowActionTests {
    @Test func aLiveServiceAlwaysHasStop() {
        let stop = ServicesScreen.RowAction.run(title: "Stop", glyph: .stop, isPrimary: false)
        #expect(ServiceStore.action(isLive: true, canStart: false) == stop)
        #expect(ServiceStore.action(isLive: true, canStart: true) == stop)
        #expect(ServiceStore.action(isLive: false, canStart: false) == .edit(title: "Edit…"))
        #expect(
            ServiceStore.action(isLive: false, canStart: true) == .run(title: "Start", glyph: .play, isPrimary: true))
    }
}

/// Services start with the environment of the user's terminal (card service-path): read once
/// from an interactive login shell, with the service's own variables on top.
@MainActor
@Suite(.serialized) struct ShellEnvironmentTests {
    private let marker = "HEADSUP_ENV_test"

    /// What the shell prints for `env`: chatter, then the environment between the markers.
    private func shellOutput(_ variables: [String], marker: String) -> String {
        "Last login: today\n\n\(marker)_BEGIN\n" + variables.map { $0 + "\0" }.joined() + "\n\(marker)_END\nbye\n"
    }

    /// The pid of the environment read: the first launch whose argv has `-i`.
    private func readPID(_ h: ServicesHarness) -> Int32? {
        h.launcher.launched.filter { $0.value.arguments.contains("-i") }.keys.sorted().last
    }

    /// The marker of a read, from its script.
    private func marker(of plan: SpawnPlan) -> String {
        let script = plan.arguments.last ?? ""
        let word = script.split(separator: " ").first { $0.hasPrefix("HEADSUP_ENV_") && $0.hasSuffix("_BEGIN;") }
        return String(word?.dropLast("_BEGIN;".count) ?? "")
    }

    /// Answers the pending read with `variables`, and lets the services start.
    private func answerRead(_ h: ServicesHarness, _ variables: [String]) async throws {
        let pid = try #require(readPID(h))
        let plan = try #require(h.launcher.launched[pid])
        h.launcher.emit(pid, shellOutput(variables, marker: marker(of: plan)))
        await h.settle()
        h.launcher.finish(pid, .code(0))
        await h.settle()
    }

    // MARK: The parse

    @Test func theParseReadsOnlyBetweenTheMarkers() {
        let output = Data(
            shellOutput(
                [
                    "PATH=/opt/homebrew/bin:/usr/bin", "GREETING=one\ntwo", "EMPTY=", "A=b=c", "noequals", "PWD=/tmp",
                    "OLDPWD=/", "SHLVL=2", "_=/usr/bin/env",
                ],
                marker: marker
            ).utf8)
        let environment = ShellEnvironment.parse(output, marker: marker)
        #expect(
            environment == [
                "PATH": "/opt/homebrew/bin:/usr/bin", "GREETING": "one\ntwo", "EMPTY": "", "A": "b=c",
            ])
        // The marker inside chatter or a value doesn't end it early.
        let tricky = Data(
            "\(marker)_END\n\n\(marker)_BEGIN\nNOTE=\n\(marker)_END\n\0X=1\0\n\(marker)_END\n".utf8)
        #expect(ShellEnvironment.parse(tricky, marker: marker) == ["NOTE": "\n\(marker)_END\n", "X": "1"])
    }

    @Test func aParseWithoutBothMarkersIsNothing() {
        #expect(ShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8), marker: marker) == nil)
        #expect(ShellEnvironment.parse(Data("\n\(marker)_BEGIN\nPATH=/usr/bin\0".utf8), marker: marker) == nil)
        #expect(ShellEnvironment.parse(Data("\n\(marker)_BEGIN\n\0\n\(marker)_END\n".utf8), marker: marker) == nil)
    }

    @Test func theScriptIsOnlyPrintfEnvAndSemicolons() {
        // printf, env -0 and `;` only: no $(…), no &&, no quoting a value.
        #expect(
            ShellEnvironment.script(marker: marker)
                == "printf '\\n%s\\n' HEADSUP_ENV_test_BEGIN; env -0; printf '\\n%s\\n' HEADSUP_ENV_test_END")
    }

    // MARK: The usual folders

    @Test func theUsualFoldersAreAppendedInOrderWhenMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a").path
        let b = root.appendingPathComponent("b").path
        let c = root.appendingPathComponent("c").path
        for folder in [a, b, c] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            #expect(chmod(folder, 0o755) == 0)
        }
        let missing = root.appendingPathComponent("missing").path
        // Appended, never prepended, in the list's order; one already there isn't added twice.
        #expect(
            ShellEnvironment.appendingFolders([c, missing, a, b], to: "/usr/bin:\(b)") == "/usr/bin:\(b):\(c):\(a)")
        #expect(ShellEnvironment.appendingFolders([a, b], to: "") == "\(a):\(b)")
        // A folder others can write to is refused.
        #expect(chmod(a, 0o775) == 0)
        #expect(chmod(b, 0o757) == 0)
        #expect(ShellEnvironment.appendingFolders([a, b, c], to: "/usr/bin") == "/usr/bin:\(c)")
        // A file isn't a folder.
        let file = root.appendingPathComponent("file").path
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        #expect(ShellEnvironment.appendingFolders([file], to: "/usr/bin") == "/usr/bin")
    }

    // Scan L1: every folder from / down counts, after links are resolved.
    @Test func aFolderUnderAWritableParentIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-path-\(UUID().uuidString)")
        defer {
            chmod(root.appendingPathComponent("open").path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
        let open = root.appendingPathComponent("open")
        let tools = open.appendingPathComponent("tools").path
        try FileManager.default.createDirectory(atPath: tools, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0 && chmod(tools, 0o755) == 0)
        #expect(ShellEnvironment.isSafeFolder(tools))
        #expect(chmod(open.path, 0o777) == 0)
        #expect(!ShellEnvironment.isSafeFolder(tools))
        // A link to it is refused the same way.
        let link = root.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: tools)
        #expect(!ShellEnvironment.isSafeFolder(link))
        #expect(ShellEnvironment.appendingFolders([tools, link], to: "/usr/bin") == "/usr/bin")
    }

    private func folder(_ owner: uid_t, _ mode: mode_t) -> (owner: uid_t, mode: mode_t) { (owner, mode) }

    @Test func aStickySharedFolderIsAllowedOnlyAboveTheUsersOwn() {
        let me = getuid()
        let other = me + 1
        let root = folder(0, 0o755)
        let sticky = folder(0, 0o1777)
        #expect(ShellEnvironment.isSafeChain([root, sticky, folder(me, 0o755)], user: me))
        #expect(!ShellEnvironment.isSafeChain([root, sticky, folder(0, 0o755)], user: me))
        #expect(!ShellEnvironment.isSafeChain([root, sticky, folder(other, 0o755)], user: me))
        // Shared without the sticky bit, or as the folder itself, it is refused.
        #expect(!ShellEnvironment.isSafeChain([root, folder(0, 0o777), folder(me, 0o755)], user: me))
        #expect(!ShellEnvironment.isSafeChain([root, sticky], user: me))
        // A folder of another user's anywhere on the way is refused.
        #expect(!ShellEnvironment.isSafeChain([root, folder(other, 0o755), folder(me, 0o755)], user: me))
        #expect(!ShellEnvironment.isSafeChain([], user: me))
    }

    @Test func onlyFoldersOwnedByRootOrTheUserAreSafe() {
        let me = getuid()
        #expect(ShellEnvironment.isSafe(owner: 0, mode: 0o755, user: me))
        #expect(ShellEnvironment.isSafe(owner: me, mode: 0o700, user: me))
        #expect(!ShellEnvironment.isSafe(owner: me + 1, mode: 0o755, user: me))
        #expect(!ShellEnvironment.isSafe(owner: 0, mode: 0o775, user: me))
        #expect(!ShellEnvironment.isSafe(owner: me, mode: 0o757, user: me))
    }

    @Test func theUsualFoldersAreTheCardsInItsOrder() {
        #expect(
            ShellEnvironment.usualFolders(home: "/Users/ana") == [
                "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/Users/ana/.local/bin",
                "/Users/ana/.cargo/bin", "/Users/ana/go/bin",
            ])
    }

    // MARK: Services

    @Test func theShellIsReadOnceAndTheServicesOwnVariablesGoOnTop() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let web = h.add(env: [EnvironmentVariable(key: "FOO", value: "service")])
        let api = h.add("API", command: "make api")
        // Nothing is read before a service starts.
        #expect(h.launcher.launched.isEmpty)
        h.services.start(web)
        // Nothing starts before the environment is read; the row looks like Starting meanwhile.
        #expect(h.launcher.launched.count == 1 && h.services.state(web) == .stopped)
        let row = try #require(h.services.screen(at: h.clock.now).rows.first { $0.id == web })
        #expect(row.status == .starting && row.action == .run(title: "Stop", glyph: .stop, isPrimary: false))
        #expect(h.services.snapshot.starting == 1)
        #expect(h.logText(web) == ["Reading your shell's environment…"])
        let readID = try #require(readPID(h))
        let read = try #require(h.launcher.launched[readID])
        #expect(read.executable == "/bin/zsh")
        #expect(Array(read.arguments.prefix(4)) == ["/bin/zsh", "-l", "-i", "-c"])
        #expect(read.directory == h.services.home)
        #expect(read.environment == ["PATH=/usr/bin"])

        try await answerRead(h, ["PATH=/Users/ana/bin:/usr/bin", "FOO=shell", "LANG=en_US.UTF-8", "PWD=/nowhere"])
        let plan = try #require(h.launcher.launched[h.pid(web)])
        // Not a login shell: its login files would put the system folders first again (Rev 1).
        #expect(plan.arguments == ["/bin/zsh", "-c", "npm run dev"])
        let environment = Dictionary(
            uniqueKeysWithValues: plan.environment.map {
                let parts = $0.split(separator: "=", maxSplits: 1)
                return (String(parts[0]), String(parts.count > 1 ? parts[1] : ""))
            })
        #expect(environment["FOO"] == "service" && environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PWD"] == nil)
        // The shell's PATH first; only folders it lacks are added after it.
        #expect(environment["PATH"]?.hasPrefix("/Users/ana/bin:/usr/bin") == true)
        #expect(h.logText(web) == ["Reading your shell's environment…", "$ npm run dev", "starting…"])

        // The second service doesn't read it again.
        h.services.start(api)
        #expect(h.launcher.launched.values.filter { $0.arguments.contains("-i") }.count == 1)
        #expect(h.launcher.launched[h.pid(api)]?.environment.contains("FOO=shell") == true)
        // The read's process was reaped.
        #expect(h.launcher.events.contains("reap \(readID)"))
    }

    @Test func fishIsReadAsFishThenRunsTheCommandInZsh() async throws {
        let h = try ServicesHarness(loginShell: "/opt/homebrew/bin/fish", readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        let readID = try #require(readPID(h))
        let read = try #require(h.launcher.launched[readID])
        #expect(read.executable == "/opt/homebrew/bin/fish")
        #expect(Array(read.arguments.prefix(4)) == ["/opt/homebrew/bin/fish", "-l", "-i", "-c"])
        try await answerRead(h, ["PATH=/Users/ana/.cargo/bin:/usr/bin"])
        let plan = try #require(h.launcher.launched[h.pid(id)])
        #expect(plan.executable == "/bin/zsh")
        #expect(plan.environment.contains { $0.hasPrefix("PATH=/Users/ana/.cargo/bin:/usr/bin") })
    }

    @Test func aReadThatTimesOutKillsItAndStartsWithHeadsUpsEnvironment() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        let pid = try #require(readPID(h))
        h.launcher.emit(pid, "Enter passphrase: ")
        await h.settle()
        h.scheduler.advance(by: 4.9)
        #expect(h.services.state(id) == .stopped)
        h.scheduler.advance(by: 0.1)
        #expect(h.launcher.events.contains("KILL \(pid)"))
        let plan = try #require(h.launcher.launched[h.pid(id)])
        #expect(plan.environment.contains { $0.hasPrefix("PATH=/usr/bin") })
        // HeadsUp's own environment: the login shell sets PATH, as before.
        #expect(plan.arguments == ["/bin/zsh", "-l", "-c", "npm run dev"])
        #expect(
            h.logText(id) == [
                "Reading your shell's environment…", "$ npm run dev", "starting…",
                "couldn't read your shell's environment (it didn't answer within 5 s); using HeadsUp's own",
            ])
        // Its process is reaped once it has exited.
        h.launcher.finish(pid, .signal(SIGKILL))
        await h.settle()
        #expect(h.launcher.events.last == "reap \(pid)")
    }

    @Test func aShellThatExitsWithoutItsEnvironmentFallsBack() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        let pid = try #require(readPID(h))
        h.launcher.emit(pid, "zsh: command not found: env\n")
        h.launcher.finish(pid, .code(127))
        await h.settle()
        // The last output may come just after the exit: it waits a moment for it.
        #expect(h.services.state(id) == .stopped)
        h.scheduler.advance(by: 1)
        #expect(
            h.logText(id).last
                == "couldn't read your shell's environment (the shell ended with code 127); using HeadsUp's own")
        #expect(h.services.state(id).isLive)
    }

    @Test func aReadThatCantStartFallsBackAtOnce() throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.launcher.failNextLaunch = LaunchError(operation: "posix_spawn /bin/zsh", code: ENOENT)
        h.services.start(id)
        #expect(h.services.state(id).isLive)
        #expect(h.logText(id).last?.hasPrefix("couldn't read your shell's environment (posix_spawn /bin/zsh: ") == true)
    }

    @Test func commandNotFoundReadsTheEnvironmentAgainAtTheNextStart() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        try await answerRead(h, ["PATH=/usr/bin"])
        h.launcher.finish(h.pid(id), .code(127))
        await h.settle()
        #expect(h.logText(id).last == "command not found: your shell's environment is read again at the next start")
        h.services.start(id)
        #expect(h.launcher.launched.values.filter { $0.arguments.contains("-i") }.count == 2)
    }

    @Test func withoutTheReadTheCommandRunsInALoginShell() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.start(id)
        #expect(h.launcher.launched[h.pid(id)]?.arguments == ["/bin/zsh", "-l", "-c", "npm run dev"])
    }

    @Test func stopWhileWaitingForTheReadCancelsTheStart() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.toggleRun(id)
        h.services.toggleRun(id)
        #expect(h.toast == .toast("Stopped Web dev server"))
        #expect(h.services.screen(at: h.clock.now).rows.first?.status == .stopped)
        try await answerRead(h, ["PATH=/usr/bin"])
        #expect(h.services.state(id) == .stopped && h.launcher.launched.count == 1)
    }

    // Scan L2: a shell that printed its environment but doesn't exit is killed, then reaped
    // when it does exit.
    @Test func aShellThatLingersAfterItsEnvironmentIsKilled() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        let pid = try #require(readPID(h))
        let plan = try #require(h.launcher.launched[pid])
        h.launcher.emit(pid, shellOutput(["PATH=/usr/bin"], marker: marker(of: plan)))
        await h.settle()
        #expect(h.services.state(id).isLive)
        h.scheduler.advance(by: 0.9)
        #expect(!h.launcher.events.contains("KILL \(pid)"))
        h.scheduler.advance(by: 0.1)
        #expect(h.launcher.events.contains("KILL \(pid)") && !h.launcher.events.contains("reap \(pid)"))
        h.launcher.finish(pid, .signal(SIGKILL))
        await h.settle()
        #expect(h.launcher.events.last == "reap \(pid)")

        // One that exits in time isn't signalled.
        let other = try ServicesHarness(readsShellEnvironment: true)
        other.services.start(other.add())
        try await answerRead(other, ["PATH=/usr/bin"])
        other.scheduler.advance(by: 1)
        #expect(!other.launcher.events.contains { $0.hasPrefix("KILL") })
    }

    @Test func autostartWaitsForTheReadThatStartsAtLaunch() async throws {
        let first = try ServicesHarness()
        let id = first.add(autostart: true)
        let data = try Data(contentsOf: first.file)
        let h = try ServicesHarness(file: String(decoding: data, as: UTF8.self), readsShellEnvironment: true)
        #expect(readPID(h) != nil && h.services.state(id) == .stopped)
        try await answerRead(h, ["PATH=/usr/bin"])
        #expect(h.services.state(id).isLive)
    }

    /// The script, run by each shell installed here: bash, zsh and fish (Rev 2). A missing one
    /// is skipped.
    @Test(arguments: [
        "/bin/bash", "/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish",
    ])
    func aRealShellPrintsItsEnvironment(shell: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let h = try ServicesHarness(
            loginShell: shell, realLauncher: true, readsShellEnvironment: true,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "MULTI": "one\ntwo"])
        let id = h.add(command: "true")
        h.services.start(id)
        // The service is started (or fails to, without zsh for fish) once the read is done.
        for _ in 0..<500 where !h.logText(id).contains("$ true") {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(h.logText(id).contains("$ true"))
        #expect(!h.logText(id).contains { $0.hasPrefix("couldn't read") })
        await h.services.stopAll()
    }
}

/// The copy of slice A of the service flags (UX: service flags §1, §2).
@Suite struct ServiceFlagsCopyTests {
    @Test func theFormsCheckboxesTooltipsAndNote() {
        #expect(Strings.ServiceForm.keepAwake == "Keep the Mac awake while it runs")
        #expect(Strings.ServiceForm.restartOnExit == "Restart if it stops")
        #expect(Strings.ServiceForm.restartOnExitHelp.contains("gives up after 5 restarts"))
        #expect(Strings.ServiceForm.keepAwakeHelp.hasSuffix("Follows Caffeine's “Only on power adapter”."))
        #expect(
            Strings.ServiceForm.runningNote
                == "Changes to the command, folder or environment apply the next time it starts.")
        #expect(Strings.Services.keepAwakeIdleHelp == "Keeps your Mac awake while it runs")
        #expect(Strings.Services.restartsHelp == "Restarts if it stops")
    }
}

/// Restart if it stops (service flags addendum §2, slice A): which exits restart, the delays,
/// the count and its resets, the give-up, the start window, and the cancel paths.
@MainActor
@Suite(.serialized) struct ServiceRestartTests {
    /// A service with Restart on, started by the user, past its start window and running.
    private func running(_ h: ServicesHarness, restartOnExit: Bool = true) -> ServiceDefinition.ID {
        let id = h.add(restartOnExit: restartOnExit)
        h.services.start(id)
        h.scheduler.advance(by: ServiceStore.startWindow)
        return id
    }

    /// The process exits by itself, after `after` seconds of running.
    private func exits(_ h: ServicesHarness, _ id: ServiceDefinition.ID, _ exit: ProcessExit, after: Double = 0)
        async
    {
        h.scheduler.advance(by: after)
        h.launcher.finish(h.pid(id), exit)
        await h.settle()
    }

    /// The restart's wait passes; the restarted run lasts past its start window.
    private func restarts(_ h: ServicesHarness, _ id: ServiceDefinition.ID) {
        guard case .waitingToRestart(_, let at, _) = h.services.state(id) else {
            Issue.record("expected a restart to wait: \(h.services.state(id))")
            return
        }
        h.scheduler.advance(by: at.timeIntervalSince(h.clock.now))
        h.scheduler.advance(by: ServiceStore.startWindow)
    }

    // MARK: Which exits restart

    @Test func codeZeroAndOthersRestartWithNoToastOrNotification() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        let launches = h.launcher.launched.count
        await exits(h, id, .code(0))
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 1, at: h.clock.now.addingTimeInterval(1), lastExit: 0))
        #expect(h.logText(id).suffix(2) == ["process exited (code 0)", "restarting in 1 s (restart 1 of 5)"])
        h.scheduler.advance(by: 1)
        guard case .starting = h.services.state(id) else {
            Issue.record("expected the restart to start")
            return
        }
        // No toast for an automatic restart (the user's Start toast is long gone).
        #expect(h.launcher.launched.count == launches + 1 && h.toast != .toast("Started Web dev server"))
        #expect(h.logText(id).suffix(2) == ["$ npm run dev", "starting…"])
        h.scheduler.advance(by: ServiceStore.startWindow)
        await exits(h, id, .signal(SIGTERM))
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 2, at: h.clock.now.addingTimeInterval(2), lastExit: 143))
        #expect(h.notifier.pending.isEmpty && !h.services.failureUnseen)
    }

    @Test func requestedStopsNeverRestart() async throws {
        // Stop.
        var h = try ServicesHarness()
        var id = running(h)
        h.services.stop(id)
        await exits(h, id, .signal(SIGTERM))
        #expect(h.services.state(id) == .stopped)

        // Restart: it starts again by itself, once.
        h = try ServicesHarness()
        id = running(h)
        let launches = h.launcher.launched.count
        h.services.restart(id)
        await exits(h, id, .signal(SIGTERM))
        guard case .starting = h.services.state(id) else {
            Issue.record("expected Restart to start it again")
            return
        }
        #expect(h.launcher.launched.count == launches + 1)

        // Delete.
        h = try ServicesHarness()
        id = running(h)
        let pid = h.pid(id)
        #expect(h.services.delete(id).isEmpty)
        h.launcher.finish(pid, .signal(SIGTERM))
        await h.settle()
        let launchesAfterDelete = h.launcher.launched.count
        h.scheduler.advance(by: 60)
        #expect(h.services.state(id) == .stopped && h.launcher.launched.count == launchesAfterDelete)

        // Without the flag, an exit is a failure, as before.
        h = try ServicesHarness()
        id = running(h, restartOnExit: false)
        await exits(h, id, .code(1))
        #expect(h.services.state(id) == .failed(exitCode: 1, at: h.clock.now))
    }

    @Test func quitCancelsAWaitingRestart() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        await exits(h, id, .code(1))
        await h.services.stopAll()
        #expect(h.services.state(id) == .stopped && h.logText(id).last == "restart cancelled")
        let launches = h.launcher.launched.count
        h.scheduler.advance(by: 60)
        #expect(h.launcher.launched.count == launches)
    }

    @Test func switchingRestartOffCancelsAWaitingRestart() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        await exits(h, id, .code(1))
        var definition = try #require(h.services.definitions.first)
        definition.restartOnExit = false
        #expect(h.services.save(definition).isEmpty)
        #expect(h.services.state(id) == .stopped && h.logText(id).last == "restart cancelled")
        let launches = h.launcher.launched.count
        h.scheduler.advance(by: 60)
        #expect(h.launcher.launched.count == launches)
    }

    // MARK: The count

    @Test func theDelaysGrowThenItGivesUpOnTheSixthStop() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        let firstExit = h.clock.now.addingTimeInterval(5)
        var waits: [TimeInterval] = []
        for _ in 1...5 {
            await exits(h, id, .code(1), after: 5)
            guard case .waitingToRestart(let attempt, let at, 1) = h.services.state(id) else {
                Issue.record("expected a restart to wait: \(h.services.state(id))")
                return
            }
            #expect(attempt == waits.count + 1)
            waits.append(at.timeIntervalSince(h.clock.now))
            restarts(h, id)
        }
        #expect(waits == [1, 2, 5, 10, 30])
        #expect(h.notifier.pending.isEmpty)

        await exits(h, id, .code(1), after: 5)
        #expect(h.services.state(id) == .failed(exitCode: 1, at: h.clock.now, gaveUpSince: firstExit))
        #expect(h.logText(id).last == "stopped again after 5 restarts; not restarting")
        #expect(h.services.failureUnseen && h.services.openLogs == id)
        let request = try #require(h.notifier.pending["service.failed:\(id)"])
        #expect(request.title == "Web dev server keeps stopping")
        #expect(request.body == "It stopped again after 5 restarts, so HeadsUp stopped restarting it.")
        #expect(request.category == .serviceFailed)
    }

    @Test func aRunOfFiveMinutesStartsTheCountOver() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        for _ in 1...3 {
            await exits(h, id, .code(1), after: 10)
            restarts(h, id)
        }
        await exits(h, id, .code(1), after: 300)
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 1, at: h.clock.now.addingTimeInterval(1), lastExit: 1))
    }

    @Test func aSlowCrashLoopStillGivesUp() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        let firstExit = h.clock.now.addingTimeInterval(90)
        for _ in 1...5 {
            await exits(h, id, .code(1), after: 90)
            restarts(h, id)
        }
        await exits(h, id, .code(1), after: 90)
        #expect(h.services.state(id) == .failed(exitCode: 1, at: h.clock.now, gaveUpSince: firstExit))
    }

    // MARK: The start window

    @Test func aUsersStartThatFailsAtOnceStaysFailed() async throws {
        let h = try ServicesHarness()
        let id = h.add(restartOnExit: true)
        h.services.start(id)
        await exits(h, id, .code(127), after: 1)
        #expect(h.services.state(id) == .failed(exitCode: 127, at: h.clock.now))
        #expect(h.notifier.pending["service.failed:\(id)"]?.title == "Web dev server stopped")
        #expect(h.services.openLogs == id)
        let launches = h.launcher.launched.count
        h.scheduler.advance(by: 60)
        #expect(
            h.launcher.launched.count == launches
                && h.services.state(id) == .failed(exitCode: 127, at: h.clock.now.addingTimeInterval(-60)))
    }

    @Test func anAutomaticRestartThatFailsAtOnceIsCountedQuietly() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        await exits(h, id, .code(1), after: 10)
        h.scheduler.advance(by: 1)  // restart 1 runs
        await exits(h, id, .code(1), after: 1)  // within its start window
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 2, at: h.clock.now.addingTimeInterval(2), lastExit: 1))
        #expect(h.notifier.pending.isEmpty)
    }

    // MARK: During the wait, and after a give-up

    @Test func stopDuringTheWaitCancelsTheRestart() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        await exits(h, id, .code(1))
        let launches = h.launcher.launched.count
        h.services.toggleRun(id)  // the row's button is Stop
        #expect(h.services.state(id) == .stopped)
        #expect(h.logText(id).last == "restart cancelled" && h.toast == .toast("Stopped Web dev server"))
        h.scheduler.advance(by: 60)
        #expect(h.launcher.launched.count == launches)
    }

    @Test func startOrRestartDuringTheWaitStartsAtOnceAndResetsTheCount() async throws {
        for useRestart in [false, true] {
            let h = try ServicesHarness()
            let id = running(h)
            for _ in 1...3 {
                await exits(h, id, .code(1), after: 10)
                restarts(h, id)
            }
            await exits(h, id, .code(1), after: 10)
            let launches = h.launcher.launched.count
            if useRestart { h.services.restart(id) } else { h.services.start(id) }
            guard case .starting = h.services.state(id) else {
                Issue.record("expected it to start at once")
                return
            }
            #expect(h.launcher.launched.count == launches + 1)
            // The wait that was armed doesn't start it again.
            h.scheduler.advance(by: 30)
            #expect(h.launcher.launched.count == launches + 1)
            await exits(h, id, .code(1), after: 10)
            #expect(
                h.services.state(id)
                    == .waitingToRestart(attempt: 1, at: h.clock.now.addingTimeInterval(1), lastExit: 1))
        }
    }

    @Test func aStartAfterAGiveUpResetsTheCount() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        for _ in 1...5 {
            await exits(h, id, .code(1), after: 5)
            restarts(h, id)
        }
        await exits(h, id, .code(1), after: 5)
        h.services.start(id)
        h.scheduler.advance(by: ServiceStore.startWindow)
        await exits(h, id, .code(1), after: 5)
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 1, at: h.clock.now.addingTimeInterval(1), lastExit: 1))
    }

    // MARK: Exit 127

    @Test func aRestartAfter127WaitsForTheEnvironmentRead() async throws {
        let h = try ServicesHarness(readsShellEnvironment: true)
        let id = h.add(restartOnExit: true)
        h.services.start(id)
        try await answerRead(h)
        h.scheduler.advance(by: ServiceStore.startWindow)
        await exits(h, id, .code(127), after: 5)
        #expect(
            h.logText(id).suffix(2) == [
                "command not found: your shell's environment is read again at the next start",
                "restarting in 1 s (restart 1 of 5)",
            ])
        let reads = readCount(h)
        h.scheduler.advance(by: 1)
        // The environment is read again first; the row looks like Starting meanwhile.
        #expect(readCount(h) == reads + 1 && h.services.state(id) == .stopped)
        #expect(h.services.screen(at: h.clock.now).rows.first?.status == .starting)
        #expect(h.logText(id).last == "Reading your shell's environment…")
        try await answerRead(h)
        guard case .starting = h.services.state(id) else {
            Issue.record("expected the restart once the environment is read")
            return
        }
        // It is still an automatic restart: failing within its window is counted, not a failure.
        await exits(h, id, .code(1), after: 1)
        #expect(
            h.services.state(id) == .waitingToRestart(attempt: 2, at: h.clock.now.addingTimeInterval(2), lastExit: 1))
    }

    private func readCount(_ h: ServicesHarness) -> Int {
        h.launcher.launched.values.filter { $0.arguments.contains("-i") }.count
    }

    /// Answers the latest environment read with a PATH, and lets the services start.
    private func answerRead(_ h: ServicesHarness) async throws {
        let pid = try #require(h.launcher.launched.filter { $0.value.arguments.contains("-i") }.keys.max())
        let script = try #require(h.launcher.launched[pid]?.arguments.last)
        let word = try #require(script.split(separator: " ").first { $0.hasSuffix("_BEGIN;") })
        let marker = String(word.dropLast("_BEGIN;".count))
        h.launcher.emit(pid, "\n\(marker)_BEGIN\nPATH=/usr/bin\0\n\(marker)_END\n")
        await h.settle()
        h.launcher.finish(pid, .code(0))
        await h.settle()
    }

    // MARK: What the row and the actions show

    @Test func theRowShowsTheFlagsTheWaitAndTheGiveUp() async throws {
        let h = try ServicesHarness()
        let plain = h.add("Plain")
        let id = h.add(keepAwake: true, restartOnExit: true)
        var rows = h.services.screen(at: h.clock.now).rows
        #expect(rows.map(\.keepsAwake) == [false, true] && rows.map(\.restarts) == [false, true])
        #expect(rows[0].accessibilityLabel == "Plain, stopped")
        #expect(
            rows[1].accessibilityLabel
                == "Web dev server, stopped, keeps your Mac awake while it runs, restarts if it stops")
        #expect(rows[1].accessibilityValue == nil)
        _ = plain

        h.services.start(id)
        h.scheduler.advance(by: ServiceStore.startWindow)
        await exits(h, id, .signal(SIGTERM), after: 10)
        rows = h.services.screen(at: h.clock.now).rows
        #expect(rows[1].status == .starting && rows[1].metaStyle == .warn)
        #expect(rows[1].meta == "Restarting in 1 s · stopped by SIGTERM")
        #expect(rows[1].action == .run(title: "Stop", glyph: .stop, isPrimary: false))
        #expect(rows[1].accessibilityValue == "restarting in 1 second")
        #expect(rows[1].accessibilityLabel.hasPrefix("Web dev server, starting, "))
        #expect(h.services.snapshot.starting == 1)

        restarts(h, id)
        await exits(h, id, .code(1), after: 10)
        #expect(
            h.services.screen(at: h.clock.now.addingTimeInterval(0.5)).rows[1].meta
                == "Restarting in 2 s · exited with code 1")
        #expect(
            h.services.screen(at: h.clock.now.addingTimeInterval(1.5)).rows[1].meta?.hasPrefix("Restarting in 1 s")
                == true)

        for _ in 2...5 {
            restarts(h, id)
            await exits(h, id, .code(1), after: 10)
        }
        guard case .failed(_, _, let since?) = h.services.state(id) else {
            Issue.record("expected a give-up")
            return
        }
        var calendar = Calendar.current
        calendar.timeZone = .current
        let row = h.services.screen(at: h.clock.now).rows[1]
        #expect(row.status == .failed && row.metaStyle == .secondary)
        #expect(row.meta == "Kept stopping since \(Format.time(since, calendar: calendar)) · gave up after 5 restarts")
        #expect(row.action == .run(title: "Start", glyph: .play, isPrimary: true))
    }

    @Test func suggestedStartStopAndRestartAreAvailableDuringTheWait() async throws {
        let h = try ServicesHarness()
        let id = running(h)
        await exits(h, id, .code(1))
        let ids = Set(ServiceActions.make(services: h.services).map(\.id.rawValue))
        #expect(ids == ["service.start:\(id)", "service.stop:\(id)", "service.restart:\(id)"])
        for verb in ["start", "stop", "restart"] {
            #expect(ServiceActions.unavailable(SuggestedActionID("service.\(verb):\(id)"), services: h.services) == nil)
        }
        // A suggested Stop, confirmed, cancels the restart.
        let stop = try #require(
            ServiceActions.make(services: h.services).first { $0.id.rawValue.hasPrefix("service.stop") })
        stop.run()
        #expect(h.services.state(id) == .stopped)
    }

    // MARK: services.json

    @Test func anOldFileLoadsWithBothFlagsOffAndTheyAreSaved() throws {
        let old = #"[{"id":"a","name":"Web","command":"npm run dev","cwd":"~","autostart":true}]"#
        let decoded = try JSONDecoder().decode([ServiceDefinition].self, from: Data(old.utf8))
        #expect(decoded.first?.keepAwake == false && decoded.first?.restartOnExit == false)

        let h = try ServicesHarness()
        let id = h.add(keepAwake: true, restartOnExit: true)
        let text = try String(contentsOf: h.file, encoding: .utf8)
        #expect(text.contains("\"keepAwake\" : true") && text.contains("\"restartOnExit\" : true"))
        let next = try ServicesHarness(file: text)
        let loaded = try #require(next.services.definitions.first { $0.id == id })
        #expect(loaded.keepAwake && loaded.restartOnExit)
    }

    @Test func theFormEditsBothFlags() throws {
        let h = try ServicesHarness()
        let id = h.add()
        h.services.editService(id)
        h.services.updateDraft {
            $0.keepAwake = true
            $0.restartOnExit = true
        }
        let screen = try #require(h.services.settingsScreen.form)
        #expect(screen.keepAwake && screen.restartOnExit)
        #expect(Strings.ServiceForm.keepAwake == "Keep the Mac awake while it runs")
        #expect(Strings.ServiceForm.restartOnExit == "Restart if it stops")
    }
}

/// The preview fakes for the service flags show each state slice A draws.
@MainActor
@Suite struct ServiceFlagsPreviewTests {
    @Test func thePreviewShowsEveryFlagState() throws {
        let model = AppModel.preview()
        model.services.showPreviewFlags()
        let rows = model.services.screen(at: model.services.clock.now, timeZone: .gmt).rows
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        let web = try #require(byName["Web dev server"])
        #expect(web.status == .running && web.keepsAwake && web.restarts)
        let postgres = try #require(byName["Postgres"])
        #expect(postgres.status == .starting && postgres.restarts && !postgres.keepsAwake)
        #expect(postgres.meta == "Restarting in 5 s · stopped by SIGTERM")
        #expect(postgres.metaStyle == .warn)
        let worker = try #require(byName["Worker"])
        #expect(worker.status == .failed)
        #expect(worker.meta?.hasPrefix("Kept stopping since ") == true)
        #expect(worker.meta?.hasSuffix(" · gave up after 5 restarts") == true)
        let ollama = try #require(byName["Ollama"])
        #expect(ollama.status == .stopped && ollama.keepsAwake && ollama.restarts)
    }
}
