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
    let picker = FakeFolderPicker()
    let terminals = FakeTerminalLauncher()
    let revealer = FakeFileRevealer()
    let folder: URL
    let work: URL
    private let ownsRoot: Bool
    private(set) var model: AppModel!
    var services: ServiceStore { model.services }

    /// `sharing` another harness uses its data folder: a second launch over the same files.
    /// `realLauncher` starts real processes.
    init(
        loginShell: String = "/bin/zsh", canDisclaim: Bool = true, file: String? = nil,
        sharing other: ServicesHarness? = nil, realLauncher: Bool = false
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
                folderPicker: picker, terminalLauncher: terminals, secrets: MemorySecretStore(),
                httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(), pasteboard: FakePasteboard(),
                dataFolder: folder, loginShell: loginShell,
                home: root.path, environment: ["PATH": "/usr/bin"]),
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
        env: [EnvironmentVariable] = [], autostart: Bool = false
    ) -> ServiceDefinition.ID {
        let definition = ServiceDefinition(
            name: name, command: command, cwd: work.path, env: env, port: port, autostart: autostart)
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
        #expect(h.model.quitQuestion?.message == "Postgres is running. Quitting stops it.")
        #expect(h.model.quitQuestion?.detail == "Your focus timer and Caffeine also stop.")
        let ollama = h.add("Ollama")
        h.services.start(ollama)
        #expect(h.model.quitQuestion?.message == "2 services are running: Postgres and Ollama. Quitting stops them.")
        #expect(h.model.quitQuestion?.quit == "Quit and Stop")
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
        #expect(h.services.settingsScreen.form?.runningNote == "Changes apply the next time it starts.")
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
