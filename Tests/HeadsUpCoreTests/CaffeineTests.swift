import Foundation
import Testing

@testable import HeadsUpCore

/// An AppModel with fake ports, keeping hold of the clock, the assertions and the power source.
@MainActor
private struct CaffeineHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let assertions = FakePowerAssertions()
    let power: FakePowerSource
    let model: AppModel
    var caffeine: CaffeineStore { model.caffeine }

    init(settings: Settings = Settings(), onBattery: Bool = false) {
        scheduler = ManualScheduler(clock: clock)
        power = FakePowerSource(isOnBattery: onBattery)
        var settings = settings
        settings.general.welcomeDone = true
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(),
                files: FakeFileRevealer(), loginItem: FakeLoginItem(), systemSettings: FakeSystemSettingsLinks(),
                notifier: FakeNotifier(), powerAssertions: assertions, powerSource: power,
                serviceLauncher: FakeServiceLauncher(), portProbe: FakePortProbe(), openPanels: FakeOpenPanels(),
                imageProcessor: FakeImageProcessor(),
                terminalLauncher: FakeTerminalLauncher(), secrets: MemorySecretStore(), httpClient: FakeHTTPClient(),
                linkOpener: FakeLinkOpener(), pasteboard: FakePasteboard(),
                dataFolder: nil),
            settings: settings)
        model.launch()
    }

    var toast: FooterLeft { model.hud.footerLeft }

    func minutes(_ count: Double) {
        scheduler.advance(by: count * 60)
    }

    func action(_ id: String) -> Action? {
        model.registry.actions.first { $0.id == ActionID(id) }
    }
}

@MainActor
@Suite struct CaffeineStoreTests {
    // MARK: On and off

    @Test func theSwitchTurnsOnWithTheLastDurationAndHoldsBothAssertions() {
        let h = CaffeineHarness()
        h.caffeine.toggle()
        #expect(h.caffeine.isOn)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(3600))
        #expect(h.assertions.held == [.displaySleep, .systemSleep])
        #expect(h.toast == .toast("Caffeine on. Your Mac stays awake"))
        #expect(h.model.tabActivity[.caffeine] == .active)
        h.caffeine.toggle()
        #expect(!h.caffeine.isOn)
        #expect(h.assertions.held.isEmpty)
        #expect(h.toast == .toast("Caffeine off"))
    }

    @Test func itTurnsOffByItselfWhenTimeIsUp() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.fifteenMinutes)
        h.minutes(14)
        #expect(h.caffeine.isOn)
        h.minutes(1)
        #expect(!h.caffeine.isOn)
        #expect(h.assertions.held.isEmpty)
    }

    @Test func afterSleepAnEndedCaffeineIsOff() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.fifteenMinutes)
        h.clock.advance(by: 3600)  // no wake-up fired while asleep
        h.model.clockJumped()
        #expect(!h.caffeine.isOn)
    }

    @Test func untilOffHasNoEnd() {
        let h = CaffeineHarness()
        h.caffeine.keepAwake(.untilOff)
        #expect(h.caffeine.endsAt == nil)
        #expect(h.toast == .toast("Caffeine on · until turned off"))
        h.minutes(24 * 60)
        #expect(h.caffeine.isOn)
        #expect(h.caffeine.snapshot == .on(endsAt: nil))
        #expect(h.caffeine.pill(at: h.clock.now) == "Awake")
    }

    @Test func aCardStartsWithAToastWhileOffAndRestartsSilentlyWhileOn() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.twoHours)
        #expect(h.toast == .toast("Caffeine on · 2 hours"))
        #expect(h.model.settings.settings.caffeine.lastDuration == .twoHours)
        h.minutes(30)
        h.model.hud.toast("something else")
        h.caffeine.selectDuration(.fifteenMinutes)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(15 * 60))
        #expect(h.toast == .toast("something else"))
        #expect(h.model.settings.settings.caffeine.lastDuration == .fifteenMinutes)
    }

    // MARK: Extend

    @Test func extendAddsToTheCurrentEnd() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.oneHour)
        h.minutes(20)
        h.caffeine.extend(minutes: 10)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(50 * 60))
        #expect(h.toast == .toast("Caffeine extended by 10 min"))
        h.caffeine.extend(minutes: 60)
        #expect(h.toast == .toast("Caffeine extended by 1 hour"))
    }

    @Test func extendFromAnEndAlreadyPassedStartsFromNow() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.fifteenMinutes)
        // The end passed while the Mac slept, and before clockJumped ran.
        h.clock.advance(by: 20 * 60)
        h.caffeine.extend(minutes: 10)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(10 * 60))
        // The expiry moved with it.
        h.minutes(9)
        #expect(h.caffeine.isOn)
        h.minutes(1)
        #expect(!h.caffeine.isOn)
    }

    @Test func untilOffCantBeExtended() {
        let h = CaffeineHarness()
        h.caffeine.keepAwake(.untilOff)
        h.caffeine.extend(minutes: 10)
        #expect(h.caffeine.endsAt == nil)
    }

    // MARK: Options

    @Test func theTwoOptionsCantBothBeOff() {
        let h = CaffeineHarness()
        h.caffeine.setOption(.keepDisplayOn, false)
        h.caffeine.setOption(.preventSystemSleep, false)
        #expect(!h.caffeine.options.keepDisplayOn)
        #expect(h.caffeine.options.preventSystemSleep)
        h.caffeine.setOption(.keepDisplayOn, true)
        h.caffeine.setOption(.preventSystemSleep, false)
        h.caffeine.setOption(.keepDisplayOn, false)
        #expect(h.caffeine.options.keepDisplayOn)
        #expect(!h.caffeine.options.preventSystemSleep)
    }

    @Test func aFileWithBothOptionsOffDecodesWithBothOn() throws {
        let json = #"{ "caffeine": { "keepDisplayOn": false, "preventSystemSleep": false, "lastDuration": "nope" } }"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.caffeine.keepDisplayOn && settings.caffeine.preventSystemSleep)
        #expect(settings.caffeine.lastDuration == .oneHour)
    }

    @Test func optionsChangedWhileOnApplyAtOnce() {
        let h = CaffeineHarness()
        h.caffeine.toggle()
        h.caffeine.setOption(.keepDisplayOn, false)
        #expect(h.assertions.held == [.systemSleep])
        h.caffeine.setOption(.keepDisplayOn, true)
        h.caffeine.setOption(.preventSystemSleep, false)
        #expect(h.assertions.held == [.displaySleep])
    }

    // MARK: Battery

    @Test func onlyOnAdapterPausesOnBatteryAndResumesOnAC() {
        var settings = Settings()
        settings.caffeine.onlyOnAC = true
        let h = CaffeineHarness(settings: settings)
        h.caffeine.selectDuration(.oneHour)
        #expect(h.assertions.held == [.displaySleep, .systemSleep])
        h.model.hud.toast("before")

        h.power.set(onBattery: true)
        #expect(h.caffeine.pausedOnBattery)
        #expect(h.assertions.held.isEmpty)
        #expect(h.caffeine.isOn)  // the switch stays on
        #expect(h.caffeine.snapshot == .on(endsAt: h.caffeine.endsAt, pausedOnBattery: true))
        #expect(h.model.statusItem.parts == [.cup(text: "1h 00m", accent: false)])
        #expect(h.toast == .toast("before"))  // no toast on power changes
        h.minutes(20)  // the countdown keeps running
        #expect(h.caffeine.pill(at: h.clock.now) == "Paused 40m")

        h.power.set(onBattery: false)
        #expect(!h.caffeine.pausedOnBattery)
        #expect(h.assertions.held == [.displaySleep, .systemSleep])
        #expect(h.model.statusItem.parts == [.cup(text: "40m", accent: true)])
    }

    @Test func onBatteryWithoutTheOptionCaffeineStaysActive() {
        let h = CaffeineHarness(onBattery: true)
        h.caffeine.toggle()
        #expect(!h.caffeine.pausedOnBattery)
        #expect(h.assertions.held == [.displaySleep, .systemSleep])
    }

    @Test func turningTheOptionOnWhileOnBatteryPausesAtOnce() {
        let h = CaffeineHarness(onBattery: true)
        h.caffeine.toggle()
        h.caffeine.setOption(.onlyOnAC, true)
        #expect(h.assertions.held.isEmpty)
    }

    // MARK: Actions, menu, pill

    @Test func theActionsFollowTheState() {
        let h = CaffeineHarness()
        #expect(h.action("caffeine.extend:10") == nil)
        #expect(h.action("caffeine.off") == nil)
        #expect(h.action("caffeine.on:oneHour")?.title == "Keep awake for 1 hour")
        h.action("caffeine.on:oneHour")?.run()
        #expect(h.toast == .toast("Caffeine on · for 1 hour"))
        #expect(h.action("caffeine.extend:10")?.title == "Add 10 min to caffeine")
        #expect(h.action("caffeine.extend:60")?.title == "Add 1 hour to caffeine")
        #expect(h.action("caffeine.off")?.subtitle == "allow sleep again")
        h.action("caffeine.on:untilOff")?.run()
        #expect(h.action("caffeine.extend:10") == nil)  // nothing to extend
        h.action("caffeine.off")?.run()
        #expect(!h.caffeine.isOn)
    }

    @Test func theMenuSwitchTogglesWithTheLastDuration() {
        let h = CaffeineHarness()
        h.model.perform(.toggleCaffeine)
        #expect(h.caffeine.isOn)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(3600))
        let row = h.model.menu.entries.compactMap { entry -> MenuRow? in
            if case .row(let row) = entry, row.action == .toggleCaffeine { return row }
            return nil
        }.first
        #expect(row?.switchIsOn == true)
        #expect(h.model.statusItem.parts == [.cup(text: "1h 00m", accent: true)])
    }

    @Test func thePillShowsTheTimeLeft() {
        let h = CaffeineHarness()
        #expect(h.caffeine.pill(at: h.clock.now) == nil)
        h.caffeine.selectDuration(.oneHour)
        #expect(h.caffeine.pill(at: h.clock.now.addingTimeInterval(2 * 60)) == "Awake 58m")
    }
}

@MainActor
@Suite struct CaffeineScreenTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let us = Locale(identifier: "en_US")

    @Test func offShowsTheSwitchOffAndNoExtendRow() {
        let h = CaffeineHarness()
        let screen = h.caffeine.screen(at: h.clock.now)
        #expect(screen.header.title == "Caffeine is off")
        #expect(screen.header.subtitle == "Your Mac sleeps and starts the screensaver as usual.")
        #expect(!screen.header.isOn && !screen.header.chipAccent)
        #expect(screen.extend == nil)
        #expect(screen.durations.map(\.title) == ["15 min", "1 hour", "2 hours", "Until off"])
        #expect(screen.durations.first { $0.isSelected }?.duration == .oneHour)
        #expect(
            screen.options.map(\.title) == ["Keep the display on", "Prevent system sleep", "Only on power adapter"])
    }

    @Test func onShowsTheTimeLeftAndWhenItEnds() {
        let h = CaffeineHarness()
        h.caffeine.selectDuration(.oneHour)
        let screen = h.caffeine.screen(at: h.clock.now.addingTimeInterval(15 * 60), locale: us, timeZone: utc)
        let endsAt = FocusStore.clockTime(h.caffeine.endsAt!, locale: us, timeZone: utc)
        #expect(screen.header.title == "Staying awake")
        #expect(screen.header.subtitle == "45m left · ends at \(endsAt)")
        #expect(screen.header.chipAccent && !screen.header.showsPauseBadge)
        #expect(screen.extend?.buttons == [.init(minutes: 10, title: "+10 min"), .init(minutes: 60, title: "+1 h")])
        h.caffeine.selectDuration(.untilOff)
        #expect(h.caffeine.screen(at: h.clock.now).header.subtitle == "Until you turn it off")
        #expect(h.caffeine.screen(at: h.clock.now).extend == nil)
    }

    @Test func pausedOnBatteryReadsAsDesigned() {
        var settings = Settings()
        settings.caffeine.onlyOnAC = true
        let h = CaffeineHarness(settings: settings, onBattery: true)
        h.caffeine.selectDuration(.oneHour)
        let screen = h.caffeine.screen(at: h.clock.now.addingTimeInterval(15 * 60), locale: us, timeZone: utc)
        #expect(screen.header.title == "Paused on battery")
        #expect(screen.header.subtitle.hasPrefix("Resumes on power · 45m left · ends at "))
        #expect(screen.header.isOn && !screen.header.chipAccent && screen.header.showsPauseBadge)
        h.caffeine.selectDuration(.untilOff)
        #expect(h.caffeine.screen(at: h.clock.now).header.subtitle == "Resumes on power")
    }

    @Test func theLastOptionOnIsDisabledWithItsTooltip() {
        let h = CaffeineHarness()
        h.caffeine.setOption(.preventSystemSleep, false)
        let rows = h.caffeine.screen(at: h.clock.now).options
        #expect(rows[0].isOn && !rows[0].isEnabled)
        #expect(rows[0].disabledHelp == "Keep at least one on.")
        #expect(!rows[1].isOn && rows[1].isEnabled)
        #expect(rows[2].isEnabled)
    }
}

/// The slice 4 fix loop: refused assertions (Yuki) and turning on while paused (Sally).
@MainActor
@Suite struct CaffeineFixLoopTests {
    @Test func whenMacOSRefusesEverythingCaffeineIsOffWithTheNote() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep, .systemSleep]
        h.model.hud.toast("before")
        h.caffeine.toggle()
        #expect(!h.caffeine.isOn)
        #expect(h.caffeine.assertionProblem == .refused)
        #expect(h.toast == .toast("before"))  // no "Caffeine on" toast
        #expect(h.model.statusItem.parts == [.appGlyph])  // no cup
        #expect(h.caffeine.pill(at: h.clock.now) == nil)
        let screen = h.caffeine.screen(at: h.clock.now)
        #expect(screen.header.title == "Caffeine is off" && !screen.header.isOn)
        #expect(screen.assertionNote?.text == "macOS didn't let HeadsUp keep your Mac awake.")
        #expect(screen.assertionNote?.tryAgain == "Try Again")
        let menuSwitch = h.model.menu.entries.compactMap { entry -> Bool? in
            if case .row(let row) = entry, row.action == .toggleCaffeine { return row.switchIsOn }
            return nil
        }.first
        #expect(menuSwitch == false)
    }

    @Test func tryAgainStartsWithTheSameDurationAndClearsTheNote() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep, .systemSleep]
        h.caffeine.selectDuration(.twoHours)
        h.assertions.refused = []
        h.caffeine.retry()
        #expect(h.caffeine.isOn)
        #expect(h.caffeine.endsAt == h.clock.now.addingTimeInterval(2 * 3600))
        #expect(h.caffeine.assertionProblem == nil)
        #expect(h.toast == .toast("Caffeine on. Your Mac stays awake"))
    }

    @Test func turningOnAnyOtherWayAlsoClearsTheNote() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep, .systemSleep]
        h.caffeine.toggle()
        h.assertions.refused = []
        h.caffeine.keepAwake(.oneHour)
        #expect(h.caffeine.assertionProblem == nil)
    }

    @Test func whenOneOfTwoIsRefusedCaffeineStaysOnWithTheOther() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep]
        h.caffeine.toggle()
        #expect(h.caffeine.isOn)
        #expect(h.assertions.held == [.systemSleep])
        #expect(h.caffeine.assertionProblem == .displayRefused)
        #expect(Strings.Caffeine.assertionNote(.displayRefused) == "macOS didn't let HeadsUp keep the display on.")
        #expect(
            Strings.Caffeine.assertionNote(.systemRefused) == "macOS didn't let HeadsUp keep your Mac from sleeping.")
    }

    @Test func turningOnWhilePausedOnBatterySaysSo() {
        var settings = Settings()
        settings.caffeine.onlyOnAC = true
        let h = CaffeineHarness(settings: settings, onBattery: true)
        h.caffeine.toggle()
        #expect(h.toast == .toast("Caffeine on · paused until you plug in"))
        h.caffeine.turnOff()
        h.caffeine.selectDuration(.oneHour)
        #expect(h.toast == .toast("Caffeine on · 1 hour · paused until you plug in"))
        h.caffeine.turnOff()
        h.caffeine.keepAwake(.twoHours)
        #expect(h.toast == .toast("Caffeine on · for 2 hours · paused until you plug in"))
        h.caffeine.extend(minutes: 10)
        #expect(h.toast == .toast("Caffeine extended by 10 min"))  // unchanged
        // Paused isn't refused: no assertions are asked for, so no note.
        #expect(h.caffeine.assertionProblem == nil)
    }
}

/// Nick's regression tests (msg-388): the refusal note describes the current session.
@MainActor
@Suite struct CaffeineNoteTests {
    @Test func aPartialNoteClearsWhenEverythingWantedIsHeld() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep]
        h.caffeine.toggle()
        #expect(h.caffeine.assertionProblem == .displayRefused)
        h.caffeine.setOption(.keepDisplayOn, false)  // held == wanted == [.systemSleep]
        #expect(h.caffeine.assertionProblem == nil)
    }

    @Test func aPartialNoteClearsWhenCaffeineTurnsOff() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep]
        h.caffeine.toggle()
        h.caffeine.turnOff()
        #expect(h.caffeine.assertionProblem == nil)
    }

    @Test func aPartialNoteClearsWhenALaterApplyWorks() {
        var settings = Settings()
        settings.caffeine.onlyOnAC = true
        let h = CaffeineHarness(settings: settings)
        h.assertions.refused = [.displaySleep]
        h.caffeine.toggle()
        h.power.set(onBattery: true)
        #expect(h.caffeine.assertionProblem == .displayRefused)  // kept through the pause
        h.assertions.refused = []
        h.power.set(onBattery: false)
        #expect(h.caffeine.assertionProblem == nil)
    }

    @Test func expiryClearsTheNote() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep]
        h.caffeine.selectDuration(.fifteenMinutes)
        h.minutes(15)
        #expect(!h.caffeine.isOn)
        #expect(h.caffeine.assertionProblem == nil)
    }

    @Test func aFullRefusalKeepsItsNoteAfterTheStop() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep, .systemSleep]
        h.caffeine.toggle()
        #expect(h.caffeine.assertionProblem == .refused)
    }

    @Test func tryAgainWhileOnKeepsTheCountdown() {
        let h = CaffeineHarness()
        h.assertions.refused = [.displaySleep]
        h.caffeine.selectDuration(.twoHours)
        let endsAt = h.caffeine.endsAt
        h.minutes(30)
        h.assertions.refused = []
        h.caffeine.retry()
        #expect(h.caffeine.endsAt == endsAt)
        #expect(h.caffeine.assertionProblem == nil)
        #expect(h.assertions.held == [.displaySleep, .systemSleep])
    }

    @Test func theCaffeineTabHasItsBody() {
        let h = CaffeineHarness()
        h.model.hud.selectTab(.caffeine)
        #expect(h.model.body == .caffeine)
        h.model.hud.setInput("awake")
        #expect(h.model.body == .suggestions)
    }
}
