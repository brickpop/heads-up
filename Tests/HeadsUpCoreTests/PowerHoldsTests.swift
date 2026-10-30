import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// An AppModel with fake power assertions, power source and launcher, and a real data folder.
@MainActor
private final class HoldsHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let assertions = FakePowerAssertions()
    let power: FakePowerSource
    let launcher = FakeServiceLauncher()
    let root: URL
    let work: URL
    private(set) var model: AppModel!
    var services: ServiceStore { model.services }
    var caffeine: CaffeineStore { model.caffeine }

    init(onBattery: Bool = false, onlyOnAC: Bool = false, readsShellEnvironment: Bool = false) throws {
        scheduler = ManualScheduler(clock: clock)
        power = FakePowerSource(isOnBattery: onBattery)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("headsup-holds-\(UUID().uuidString)")
        work = root.appendingPathComponent("web-app")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var settings = Settings()
        settings.general.welcomeDone = true
        settings.caffeine.onlyOnAC = onlyOnAC
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(),
                files: FakeFileRevealer(), loginItem: FakeLoginItem(), systemSettings: FakeSystemSettingsLinks(),
                notifier: FakeNotifier(), powerAssertions: assertions, powerSource: power,
                serviceLauncher: launcher, portProbe: FakePortProbe(), openPanels: FakeOpenPanels(),
                imageProcessor: FakeImageProcessor(), calendar: FakeCalendarReader(),
                reminders: FakeRemindersAccess(), terminalLauncher: FakeTerminalLauncher(),
                secrets: MemorySecretStore(), httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(),
                pasteboard: FakePasteboard(), dataFolder: root.appendingPathComponent("HeadsUp"),
                home: root.path, environment: ["PATH": "/usr/bin"], readsShellEnvironment: readsShellEnvironment),
            settings: settings)
        model.launch()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func add(_ name: String = "Web dev server", keepAwake: ServiceKeepAwake = .unlimited, restartOnExit: Bool = false)
        -> ServiceDefinition.ID
    {
        let definition = ServiceDefinition(
            name: name, command: "npm run dev", cwd: work.path, keepAwake: keepAwake, restartOnExit: restartOnExit)
        #expect(services.save(definition).isEmpty)
        return definition.id
    }

    func pid(_ id: ServiceDefinition.ID) -> Int32 { services.state(id).pid ?? 0 }
    func log(_ id: ServiceDefinition.ID) -> [String] { services.logLines(id).map(\.text) }
    func held(_ id: ServiceDefinition.ID) -> Set<PowerAssertionKind> { assertions.held(by: .service(id)) }
    func row(_ id: ServiceDefinition.ID) -> ServicesScreen.Row? {
        services.screen(at: clock.now).rows.first { $0.id == id }
    }
    var header: CaffeineScreen.Header { caffeine.screen(at: clock.now).header }

    /// The process exits by itself, and the callbacks run.
    func exits(_ id: ServiceDefinition.ID, _ exit: ProcessExit = .code(1), after: Double = 0) async {
        scheduler.advance(by: after)
        launcher.finish(pid(id), exit)
        for _ in 0..<5 { await Task.yield() }
    }
}

/// Keep the Mac awake while it runs, and the one owner of power assertions (service flags
/// addendum §3–4, slice B).
@MainActor
@Suite(.serialized) struct PowerHoldsTests {
    // MARK: PowerHolds

    @Test func theUnionOfEveryHolderIsHeldAndEachReleasesOnlyItsOwn() {
        let assertions = FakePowerAssertions()
        let holds = PowerHolds(
            assertions: assertions, power: FakePowerSource(), settings: SettingsStore(folder: nil, clock: ManualClock())
        )
        #expect(
            holds.set(.caffeine, kinds: [.displaySleep, .systemSleep], name: "HeadsUp: Caffeine")
                == [.displaySleep, .systemSleep])
        #expect(holds.set(.service("a"), kinds: [.systemSleep], name: "HeadsUp: web") == [.systemSleep])
        #expect(holds.set(.service("b"), kinds: [.systemSleep], name: "HeadsUp: web") == [.systemSleep])
        // Two services with the same name are two holds.
        #expect(assertions.holds.count == 4)
        holds.set(.service("a"), kinds: [], name: "")
        #expect(assertions.held(by: .service("a")).isEmpty && assertions.held(by: .service("b")) == [.systemSleep])
        #expect(assertions.held(by: .caffeine) == [.displaySleep, .systemSleep])
        holds.set(.caffeine, kinds: [], name: "")
        #expect(assertions.held == [.systemSleep] && assertions.name(of: .service("b")) == "HeadsUp: web")
    }

    @Test func aRefusalIsMappedToItsHolder() {
        let assertions = FakePowerAssertions()
        assertions.refusedHolders = [.service("a")]
        let holds = PowerHolds(
            assertions: assertions, power: FakePowerSource(), settings: SettingsStore(folder: nil, clock: ManualClock())
        )
        #expect(holds.set(.service("a"), kinds: [.systemSleep], name: "HeadsUp: a").isEmpty)
        #expect(holds.set(.service("b"), kinds: [.systemSleep], name: "HeadsUp: b") == [.systemSleep])
        #expect(holds.set(.caffeine, kinds: [.systemSleep], name: "HeadsUp: Caffeine") == [.systemSleep])
    }

    // MARK: A service's hold

    @Test func aServiceHoldsSystemSleepWhileItRunsAndReleasesOnStop() async throws {
        let h = try HoldsHarness()
        let id = h.add()
        #expect(h.row(id)?.awake == nil && h.held(id).isEmpty)
        #expect(h.row(id)?.accessibilityLabel == "Web dev server, stopped, keeps your Mac awake while it runs")
        h.services.start(id)
        #expect(h.held(id) == [.systemSleep])
        #expect(h.assertions.name(of: .service(id)) == "HeadsUp: Web dev server")
        #expect(h.log(id) == ["$ npm run dev", "starting…", "keeping the Mac awake"])
        #expect(h.row(id)?.awake == .holding)
        #expect(h.row(id)?.accessibilityLabel == "Web dev server, starting, keeping your Mac awake")
        #expect(h.services.serviceHolds == [ServiceHold(name: "Web dev server", awake: .holding)])
        // Only system sleep: the display may sleep.
        #expect(!h.assertions.held.contains(.displaySleep))

        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil)
        #expect(h.log(id).last == "no longer keeping the Mac awake")
        #expect(h.services.serviceHolds.isEmpty)
    }

    @Test func withoutTheFlagNothingIsHeld() throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .off)
        h.services.start(id)
        #expect(h.assertions.holds.isEmpty && h.row(id)?.awake == nil)
        #expect(!h.log(id).contains("keeping the Mac awake"))
    }

    @Test func twoServicesWithTheSameNameAreTwoHolds() async throws {
        let h = try HoldsHarness()
        let a = h.add("web")
        let b = h.add("web")
        h.services.start(a)
        h.services.start(b)
        #expect(h.held(a) == [.systemSleep] && h.held(b) == [.systemSleep])
        h.services.stop(a)
        await h.exits(a, .signal(SIGTERM))
        #expect(h.held(a).isEmpty && h.held(b) == [.systemSleep])
    }

    @Test func aRenameKeepsTheHold() throws {
        let h = try HoldsHarness()
        let id = h.add()
        h.services.start(id)
        var definition = try #require(h.services.definitions.first)
        definition.name = "API"
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(id) == [.systemSleep] && h.log(id).filter { $0 == "keeping the Mac awake" }.count == 1)
        #expect(h.services.serviceHolds.first?.name == "API")
    }

    @Test func switchingKeepAwakeOnOrOffTakesOrReleasesItOnSave() throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .off)
        h.services.start(id)
        var definition = try #require(h.services.definitions.first)
        definition.keepAwake = .unlimited
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(id) == [.systemSleep] && h.log(id).last == "keeping the Mac awake")
        definition.keepAwake = .off
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(id).isEmpty && h.log(id).last == "no longer keeping the Mac awake")
        #expect(h.services.state(id).isLive)
    }

    @Test func caffeineAndServicesAreIndependent() async throws {
        let h = try HoldsHarness()
        let id = h.add()
        h.services.start(id)
        h.caffeine.toggle()
        #expect(h.assertions.held(by: .caffeine) == [.displaySleep, .systemSleep] && h.held(id) == [.systemSleep])
        // Caffeine off leaves the service's hold.
        h.caffeine.toggle()
        #expect(h.assertions.held(by: .caffeine).isEmpty && h.held(id) == [.systemSleep])
        // A service's hold doesn't turn Caffeine on, and a timer ending doesn't touch it.
        #expect(!h.caffeine.isOn && h.caffeine.snapshot.state == .off)
        h.caffeine.selectDuration(.fifteenMinutes)
        h.scheduler.advance(by: 15 * 60)
        #expect(!h.caffeine.isOn && h.held(id) == [.systemSleep])
        // The service ending doesn't touch Caffeine.
        h.caffeine.toggle()
        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        #expect(h.caffeine.isOn && h.assertions.held(by: .caffeine) == [.displaySleep, .systemSleep])
    }

    @Test func onlyOnPowerAdapterPausesEveryHolder() throws {
        let h = try HoldsHarness(onlyOnAC: true)
        // The option says it covers the services too (Yuki).
        let option = h.caffeine.screen(at: h.clock.now).options.first { $0.option == .onlyOnAC }
        #expect(option?.help == "Pauses on battery. This also pauses services that keep your Mac awake.")
        let id = h.add()
        h.services.start(id)
        h.caffeine.toggle()
        h.power.set(onBattery: true)
        #expect(h.assertions.holds.isEmpty)
        #expect(h.row(id)?.awake == .pausedOnBattery && h.caffeine.pausedOnBattery)
        #expect(h.log(id).suffix(2) == ["keeping the Mac awake", "keeping awake paused: on battery"])
        #expect(h.row(id)?.accessibilityLabel.hasSuffix("keeping awake is paused on battery") == true)
        h.power.set(onBattery: false)
        #expect(h.held(id) == [.systemSleep] && h.assertions.held(by: .caffeine) == [.displaySleep, .systemSleep])
        #expect(h.row(id)?.awake == .holding && h.log(id).last == "keeping awake resumed: on power")
        // Switching the option off on battery resumes everyone.
        h.power.set(onBattery: true)
        h.caffeine.setOption(.onlyOnAC, false)
        #expect(h.held(id) == [.systemSleep] && h.row(id)?.awake == .holding)
    }

    // Rev NIT 1: a refused hold isn't asked for again behind its holder's back, so its row never
    // says refused while macOS grants it. Its holder asking again tries it again.
    @Test func aRefusedHoldIsTriedAgainOnlyWhenItsHolderAsks() throws {
        let assertions = FakePowerAssertions()
        assertions.refusedHolders = [.service("a")]
        let holds = PowerHolds(
            assertions: assertions, power: FakePowerSource(), settings: SettingsStore(folder: nil, clock: ManualClock())
        )
        #expect(holds.set(.service("a"), kinds: [.systemSleep], name: "HeadsUp: a").isEmpty)
        assertions.refusedHolders = []
        holds.set(.service("b"), kinds: [.systemSleep], name: "HeadsUp: b")
        holds.set(.caffeine, kinds: [.displaySleep], name: "HeadsUp: Caffeine")
        #expect(assertions.held(by: .service("a")).isEmpty)
        #expect(holds.set(.service("a"), kinds: [.systemSleep], name: "HeadsUp: a") == [.systemSleep])
    }

    @Test func aRefusedServiceStaysRefusedUntilItAsksAgain() throws {
        let h = try HoldsHarness()
        let refused = h.add()
        h.assertions.refusedHolders = [.service(refused)]
        h.services.start(refused)
        h.assertions.refusedHolders = []
        // Another holder's change doesn't grant it silently.
        h.services.start(h.add("Postgres"))
        h.caffeine.toggle()
        #expect(h.held(refused).isEmpty && h.row(refused)?.awake == .refused)
        // Saving it (its holder asks again) does, and says so.
        var definition = try #require(h.services.definitions.first { $0.id == refused })
        definition.name = "Web"
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(refused) == [.systemSleep] && h.row(refused)?.awake == .holding)
        #expect(h.log(refused).last == "keeping the Mac awake")
    }

    // Rev NIT 2: a start that waits for the shell's environment holds meanwhile, and Stop during
    // that wait releases it.
    @Test func aStartWaitingForTheShellReadHoldsAndStopReleasesIt() throws {
        let h = try HoldsHarness(readsShellEnvironment: true)
        let id = h.add()
        h.services.start(id)
        #expect(h.services.state(id) == .stopped && h.services.isWaitingForEnvironment(id))
        #expect(h.held(id) == [.systemSleep] && h.row(id)?.awake == .holding)
        #expect(h.log(id) == ["Reading your shell's environment…", "keeping the Mac awake"])
        h.services.stop(id)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil)
        #expect(h.log(id).last == "no longer keeping the Mac awake")
    }

    @Test func aRefusedHoldDoesntStopTheServiceAndSaysSo() throws {
        let h = try HoldsHarness()
        let id = h.add()
        h.assertions.refusedHolders = [.service(id)]
        h.services.start(id)
        #expect(h.services.state(id).isLive && h.row(id)?.awake == .refused)
        #expect(h.log(id).last == "macOS didn't let HeadsUp keep the Mac awake")
        #expect(h.row(id)?.accessibilityLabel == "Web dev server, starting, can't keep your Mac awake")
        let screen = h.caffeine.screen(at: h.clock.now)
        #expect(screen.refusedLine == "macOS didn't let HeadsUp keep your Mac awake for Web dev server.")
        #expect(screen.header.title == "Caffeine is off")
        // Caffeine still holds its own.
        h.caffeine.toggle()
        #expect(h.caffeine.isOn && h.caffeine.assertionProblem == nil)
    }

    // Both flags: the hold stays through the restart wait, and goes at the give-up.
    @Test func bothFlagsHoldThroughTheWaitAndReleaseAtTheGiveUp() async throws {
        let h = try HoldsHarness()
        let id = h.add(restartOnExit: true)
        h.services.start(id)
        h.scheduler.advance(by: ServiceStore.startWindow)
        for _ in 1...5 {
            await h.exits(id, after: 5)
            guard case .waitingToRestart(_, let at, _) = h.services.state(id) else {
                Issue.record("expected a wait")
                return
            }
            #expect(h.held(id) == [.systemSleep] && h.row(id)?.awake == .holding)
            h.scheduler.advance(by: at.timeIntervalSince(h.clock.now) + ServiceStore.startWindow)
        }
        #expect(h.log(id).filter { $0 == "keeping the Mac awake" }.count == 1)
        await h.exits(id, after: 5)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil)
        #expect(
            h.log(id).suffix(2) == [
                "stopped again after 5 restarts; not restarting", "no longer keeping the Mac awake",
            ])
    }

    @Test func stopDuringTheWaitReleasesTheHold() async throws {
        let h = try HoldsHarness()
        let id = h.add(restartOnExit: true)
        h.services.start(id)
        h.scheduler.advance(by: ServiceStore.startWindow)
        await h.exits(id, after: 5)
        h.services.stop(id)
        #expect(h.held(id).isEmpty)
        #expect(h.log(id).suffix(2) == ["restart cancelled", "no longer keeping the Mac awake"])
    }

    @Test func deletingAServiceReleasesItsHold() async throws {
        let h = try HoldsHarness()
        let id = h.add()
        h.services.start(id)
        let pid = h.pid(id)
        #expect(h.services.delete(id).isEmpty)
        h.launcher.finish(pid, .signal(SIGTERM))
        for _ in 0..<5 { await Task.yield() }
        #expect(h.held(id).isEmpty && h.services.serviceHolds.isEmpty)
    }

    // MARK: Caffeine tab, menu bar, menu and tab dot

    @Test func caffeineOffAndHeldSaysWhoKeepsTheMacAwake() throws {
        let h = try HoldsHarness()
        let web = h.add()
        h.services.start(web)
        var header = h.header
        #expect(header.title == "Kept awake by Web dev server" && !header.isOn)
        #expect(header.subtitle == "Caffeine is off. Your Mac stays awake while it runs.")
        #expect(header.chipAccent && header.showsServerBadge && !header.showsPauseBadge)
        #expect(h.caffeine.screen(at: h.clock.now).heldLine == nil)
        #expect(h.model.tabActivity[.caffeine] == .active)

        let item = StatusItemModel(
            focus: h.model.focus.snapshot, caffeine: h.caffeine.snapshot, now: h.clock.now, promptVisible: false,
            showSeconds: false)
        #expect(item.parts == [.cup(text: nil, accent: false)])
        #expect(item.accessibilityLabel == "HeadsUp, kept awake by Web dev server")
        let menu = h.model.menu
        #expect(menu.entries.contains(.note("Kept awake by Web dev server")))

        let postgres = h.add("Postgres")
        h.services.start(postgres)
        header = h.header
        #expect(header.title == "Kept awake by 2 services")
        #expect(header.subtitle == "Caffeine is off. Web dev server and Postgres keep your Mac awake while they run.")
        h.services.start(h.add("Redis"))
        #expect(
            h.header.subtitle
                == "Caffeine is off. Web dev server, Postgres and 1 more keep your Mac awake while they run.")

        // Caffeine on: its own header, with the held line under it.
        h.caffeine.toggle()
        let on = h.caffeine.screen(at: h.clock.now)
        #expect(on.header.isOn && on.header.title != "Kept awake by 3 services" && !on.header.showsServerBadge)
        #expect(on.heldLine == "Web dev server, Postgres and 1 more also keep your Mac awake while they run.")
        let onItem = StatusItemModel(
            focus: h.model.focus.snapshot, caffeine: h.caffeine.snapshot, now: h.clock.now, promptVisible: false,
            showSeconds: false)
        // Caffeine on: the accent cup with its time, as before.
        guard case .cup(_?, true)? = onItem.parts.first else {
            Issue.record("expected the accent cup with a time: \(onItem.parts)")
            return
        }
    }

    @Test func oneServiceAlsoKeepsItWhileCaffeineIsOn() throws {
        let h = try HoldsHarness()
        h.services.start(h.add())
        h.caffeine.toggle()
        #expect(
            h.caffeine.screen(at: h.clock.now).heldLine == "Web dev server also keeps your Mac awake while it runs.")
    }

    @Test func heldOnlyAndPausedOnBatterySaysItResumesOnPower() throws {
        let h = try HoldsHarness(onBattery: true, onlyOnAC: true)
        h.services.start(h.add())
        let header = h.header
        #expect(header.title == "Paused on battery" && !header.isOn)
        #expect(header.subtitle == "Web dev server would keep your Mac awake. Resumes on power.")
        #expect(!header.chipAccent && header.showsPauseBadge && !header.showsServerBadge)
        #expect(h.model.tabActivity[.caffeine] == .active)
        let item = StatusItemModel(
            focus: h.model.focus.snapshot, caffeine: h.caffeine.snapshot, now: h.clock.now, promptVisible: false,
            showSeconds: false)
        #expect(item.parts == [.cup(text: nil, accent: false)])
        #expect(!h.model.menu.entries.contains { if case .note = $0 { true } else { false } })
    }

    @Test func nothingHeldLooksAsBefore() throws {
        let h = try HoldsHarness()
        h.add()
        #expect(h.header.title == "Caffeine is off" && !h.header.chipAccent && !h.header.showsServerBadge)
        #expect(h.model.tabActivity[.caffeine] == nil)
        let item = StatusItemModel(
            focus: h.model.focus.snapshot, caffeine: h.caffeine.snapshot, now: h.clock.now, promptVisible: false,
            showSeconds: false)
        #expect(item.parts == [.appGlyph])
    }

    @Test func theCupTooltipFollowsTheHold() {
        #expect(Strings.Services.keepAwakeTooltip(.holding) == "Keeping your Mac awake")
        #expect(Strings.Services.keepAwakeTooltip(.pausedOnBattery) == "Keeping awake is paused on battery")
        #expect(Strings.Services.keepAwakeTooltip(.refused) == "macOS didn't let HeadsUp keep your Mac awake")
        #expect(Strings.Services.keepAwakeTooltip(nil) == "Keeps your Mac awake while it runs")
    }
}

/// Keep awake for 30m, 2h, 5h or without a limit (keep-awake limit addendum §5): the stored
/// shape, and when the limit counts, runs out and starts over.
@MainActor
@Suite(.serialized) struct ServiceKeepAwakeLimitTests {
    private static let minute: TimeInterval = 60

    private func decode(_ json: String) throws -> ServiceKeepAwake {
        try JSONDecoder().decode(ServiceDefinition.self, from: Data(json.utf8)).keepAwake
    }

    private func ended(_ h: HoldsHarness, _ id: ServiceDefinition.ID) -> [LogLine] {
        h.services.logLines(id).filter { $0.text.hasSuffix("limit reached") }
    }

    /// Moves the clock to `start` plus `minutes`, running what is due on the way.
    private func advance(_ h: HoldsHarness, to minutes: Double, from start: Date) {
        h.scheduler.advance(by: start.addingTimeInterval(minutes * Self.minute).timeIntervalSince(h.clock.now))
    }

    @Test func theOldBoolReadsAsUnlimitedOrOffAndOnlyTheNewKeyIsWritten() throws {
        let base = #""id":"a","name":"Web","command":"npm run dev""#
        #expect(try decode("{\(base),\"keepAwake\":true}") == .unlimited)
        #expect(try decode("{\(base),\"keepAwake\":false}") == .off)
        #expect(try decode("{\(base)}") == .off)
        #expect(try decode("{\(base),\"keepAwake\":true,\"keepAwakeFor\":\"thirtyMinutes\"}") == .thirtyMinutes)
        // A hand-edited value this build doesn't know never holds longer than asked.
        #expect(try decode("{\(base),\"keepAwake\":true,\"keepAwakeFor\":\"45m\"}") == .off)
        #expect(try decode("{\(base),\"keepAwakeFor\":7}") == .off)

        let definition = ServiceDefinition(id: "a", name: "Web", command: "npm run dev", keepAwake: .fiveHours)
        let text = try #require(String(data: JSONEncoder().encode(definition), encoding: .utf8))
        #expect(text.contains(#""keepAwakeFor":"fiveHours""#) && !text.contains(#""keepAwake":"#))
        #expect(try decode(text) == .fiveHours)
        #expect(ServiceKeepAwake.allCases.map(\.minutes) == [nil, 30, 120, 300, nil])
        #expect(
            ServiceKeepAwake.allCases.map(Strings.ServiceForm.keepAwakeChoice) == [
                "Off", "30m", "2h", "5h", "Unlimited",
            ])
    }

    @Test func aDefinitionWithEveryFieldSetComesBackTheSame() throws {
        // Every field differs from its default, so a field the encoder drops or the decoder
        // misreads shows as a difference.
        let definition = ServiceDefinition(
            id: "web-1", name: "Web", command: "npm run dev -- --port 5173", cwd: "~/code/web",
            env: [
                EnvironmentVariable(key: "NODE_ENV", value: "development"), EnvironmentVariable(key: "A", value: ""),
            ],
            port: 5173, autostart: true, keepAwake: .twoHours, restartOnExit: true)
        let decoded = try JSONDecoder().decode(ServiceDefinition.self, from: JSONEncoder().encode(definition))
        #expect(decoded == definition)
    }

    @Test func thirtyMinutesReleasesTheHoldAndTheServiceKeepsRunning() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 30 - 1.0 / 60, from: start)
        #expect(h.held(id) == [.systemSleep] && h.row(id)?.awake == .holding)
        #expect(h.row(id)?.keepsAwake == true)

        advance(h, to: 30, from: start)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil && h.services.serviceHolds.isEmpty)
        guard case .running = h.services.state(id) else {
            Issue.record("expected it still running, got \(h.services.state(id))")
            return
        }
        #expect(ended(h, id).map(\.text) == ["no longer keeping the Mac awake: 30m limit reached"])
        #expect(!h.log(id).contains("no longer keeping the Mac awake"))
        // Stop later says nothing more about the hold.
        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        #expect(ended(h, id).count == 1 && !h.log(id).contains("no longer keeping the Mac awake"))
    }

    @Test func anAutomaticRestartDoesntResetTheCount() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes, restartOnExit: true)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 20, from: start)
        await h.exits(id)
        guard case .waitingToRestart(_, let at, _) = h.services.state(id) else {
            Issue.record("expected a wait, got \(h.services.state(id))")
            return
        }
        h.scheduler.advance(by: at.timeIntervalSince(h.clock.now) + ServiceStore.startWindow)
        #expect(h.services.state(id).pid != nil && h.held(id) == [.systemSleep])

        advance(h, to: 30, from: start)
        #expect(h.held(id).isEmpty && h.services.state(id).isLive)
        #expect(ended(h, id).count == 1)
    }

    @Test func aManualRestartResetsTheCount() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 20, from: start)
        h.services.restart(id)
        await h.exits(id, .signal(SIGTERM))
        #expect(h.services.state(id).isLive && h.held(id) == [.systemSleep])

        advance(h, to: 50 - 1.0 / 60, from: start)
        #expect(h.held(id) == [.systemSleep] && ended(h, id).isEmpty)
        advance(h, to: 50, from: start)
        #expect(h.held(id).isEmpty && h.services.state(id).isLive)
        #expect(ended(h, id).count == 1)

        // A Start after a Stop counts from the start again, after an expiry too.
        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        let again = h.clock.now
        h.services.start(id)
        #expect(h.held(id) == [.systemSleep])
        advance(h, to: 30, from: again)
        #expect(h.held(id).isEmpty && ended(h, id).count == 2)
    }

    @Test func aNewLimitOnALiveServiceCountsFromTheSave() throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 20, from: start)
        var definition = try #require(h.services.definitions.first { $0.id == id })
        definition.keepAwake = .twoHours
        #expect(h.services.save(definition).isEmpty)

        advance(h, to: 140 - 1.0 / 60, from: start)
        #expect(h.held(id) == [.systemSleep] && ended(h, id).isEmpty)
        advance(h, to: 140, from: start)
        #expect(h.held(id).isEmpty && h.services.state(id).isLive)
        #expect(ended(h, id).map(\.text) == ["no longer keeping the Mac awake: 2h limit reached"])

        // Saving something else doesn't start the count again.
        definition.name = "Web"
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil)
    }

    @Test func theLimitKeepsCountingWhilePausedOnBattery() throws {
        let h = try HoldsHarness(onlyOnAC: true)
        let id = h.add(keepAwake: .thirtyMinutes)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 10, from: start)
        h.power.set(onBattery: true)
        #expect(h.row(id)?.awake == .pausedOnBattery)

        advance(h, to: 30, from: start)
        #expect(h.row(id)?.awake == nil)
        #expect(ended(h, id).map(\.time) == [start.addingTimeInterval(30 * Self.minute)])

        advance(h, to: 40, from: start)
        h.power.set(onBattery: false)
        #expect(h.held(id).isEmpty && h.row(id)?.awake == nil && h.services.state(id).isLive)
        #expect(!h.log(id).contains("keeping awake resumed: on power"))
        #expect(ended(h, id).count == 1)
    }

    @Test func aClockJumpPastTheEndReleasesTheHoldAtOnce() throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .thirtyMinutes)
        h.services.start(id)
        // The Mac slept: the clock moved, and no timer has fired yet.
        h.clock.advance(by: 45 * Self.minute)
        #expect(h.held(id) == [.systemSleep])
        h.model.clockJumped()
        #expect(h.held(id).isEmpty && h.services.state(id).isLive)
        #expect(ended(h, id).count == 1)
        // The late timer doesn't log it twice.
        h.scheduler.advance(by: 0)
        #expect(ended(h, id).count == 1)
    }

    @Test func unlimitedNeverSchedulesAnEnd() throws {
        let h = try HoldsHarness()
        let unlimited = h.add("Ollama", keepAwake: .unlimited)
        let limited = h.add("Web", keepAwake: .thirtyMinutes)
        var pending = h.scheduler.pendingCount
        h.services.start(unlimited)
        let unlimitedJobs = h.scheduler.pendingCount - pending
        pending = h.scheduler.pendingCount
        h.services.start(limited)
        #expect(h.scheduler.pendingCount - pending == unlimitedJobs + 1)

        h.scheduler.advance(by: 24 * 60 * Self.minute)
        #expect(h.held(unlimited) == [.systemSleep] && h.row(unlimited)?.awake == .holding)
        #expect(ended(h, unlimited).isEmpty)
    }

    // Yuki BLOCKING 1 and NIT 6: the row says the limit, then that it ended, until a start.
    @Test func theRowSaysTheLimitThenThatItEndedUntilTheNextStart() async throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .twoHours)
        var row = try #require(h.row(id))
        #expect(row.keepAwakeHelp == "Keeps your Mac awake for 2h after it starts" && !row.keepAwakeEnded)
        #expect(row.accessibilityLabel == "Web dev server, stopped, keeps your Mac awake while it runs")

        let start = h.clock.now
        h.services.start(id)
        #expect(h.row(id)?.keepAwakeHelp == "Keeping your Mac awake")
        advance(h, to: 120, from: start)
        row = try #require(h.row(id))
        #expect(row.status == .running && row.awake == nil && row.keepAwakeEnded)
        #expect(row.keepAwakeHelp == "Stopped keeping your Mac awake after 2h")
        #expect(row.accessibilityLabel == "Web dev server, running, stopped keeping your Mac awake after 2 hours")
        // It isn't a hold: Caffeine and the menu bar don't list it.
        #expect(h.services.serviceHolds.isEmpty)

        // A manual Restart starts the count again, and the row holds again.
        h.services.restart(id)
        await h.exits(id, .signal(SIGTERM))
        row = try #require(h.row(id))
        #expect(!row.keepAwakeEnded && row.awake == .holding && row.keepAwakeHelp == "Keeping your Mac awake")

        // Stopped after it ended, the row is back to the limit.
        advance(h, to: 240 + 1, from: start)
        #expect(h.row(id)?.keepAwakeEnded == true)
        h.services.stop(id)
        await h.exits(id, .signal(SIGTERM))
        row = try #require(h.row(id))
        #expect(!row.keepAwakeEnded && row.keepAwakeHelp == "Keeps your Mac awake for 2h after it starts")
    }

    // Yuki NIT 5: the log line names the limit; NIT 3 and BLOCKING 2: the form's label and the
    // choices VoiceOver reads.
    @Test func theLogLineAndTheFormCopy() throws {
        #expect(Strings.Services.keepAwakeEnded(.fiveHours) == "no longer keeping the Mac awake: 5h limit reached")
        #expect(Strings.ServiceForm.keepAwake == "Keep your Mac awake")
        #expect(
            ServiceKeepAwake.allCases.map(Strings.ServiceForm.keepAwakeChoiceSpoken) == [
                "Off", "30 minutes", "2 hours", "5 hours", "Unlimited",
            ])
        #expect(Strings.Services.keepAwakeTooltip(nil, limit: .unlimited) == "Keeps your Mac awake while it runs")
        #expect(Strings.Services.keepAwakeTooltip(nil) == "Keeps your Mac awake while it runs")
        // The duration follows the limit: short in the tooltip, spoken by VoiceOver (Yuki 1, 6).
        #expect(
            Strings.Services.keepAwakeTooltip(nil, limit: .thirtyMinutes, ended: true)
                == "Stopped keeping your Mac awake after 30m")
        #expect(
            Strings.Services.rowAccessibility(
                name: "Web", status: .running, keepsAwake: true, ended: .fiveHours, restarts: false)
                == "Web, running, stopped keeping your Mac awake after 5 hours")
    }

    // Nick NIT 1: with Keep awake off, nothing counts, and turning it on counts from the save.
    @Test func offCountsNothingAndTurningItOnCountsFromTheSave() throws {
        let h = try HoldsHarness()
        let id = h.add(keepAwake: .off)
        let start = h.clock.now
        h.services.start(id)
        advance(h, to: 45, from: start)
        h.model.clockJumped()
        #expect(h.held(id).isEmpty && ended(h, id).isEmpty)

        var definition = try #require(h.services.definitions.first { $0.id == id })
        definition.keepAwake = .thirtyMinutes
        #expect(h.services.save(definition).isEmpty)
        #expect(h.held(id) == [.systemSleep])
        advance(h, to: 75 - 1.0 / 60, from: start)
        #expect(h.held(id) == [.systemSleep])
        advance(h, to: 75, from: start)
        #expect(h.held(id).isEmpty && ended(h, id).count == 1)
    }
}
