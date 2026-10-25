import Foundation
import Testing

@testable import HeadsUpCore

/// An AppModel with fake ports, keeping hold of the clock, scheduler, window and notifier.
@MainActor
private struct FocusHarness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let notifier = FakeNotifier()
    let window = FakeHUDWindow()
    let model: AppModel
    var focus: FocusStore { model.focus }
    var hud: HUDStore { model.hud }

    init(settings: Settings = Settings()) {
        scheduler = ManualScheduler(clock: clock)
        var settings = settings
        settings.general.welcomeDone = true
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: scheduler, hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(),
                files: FakeFileRevealer(), loginItem: FakeLoginItem(), systemSettings: FakeSystemSettingsLinks(),
                notifier: notifier, powerAssertions: FakePowerAssertions(), powerSource: FakePowerSource(),
                serviceLauncher: FakeServiceLauncher(), portProbe: FakePortProbe(), openPanels: FakeOpenPanels(),
                imageProcessor: FakeImageProcessor(),
                terminalLauncher: FakeTerminalLauncher(), secrets: MemorySecretStore(), httpClient: FakeHTTPClient(),
                linkOpener: FakeLinkOpener(), pasteboard: FakePasteboard(),
                dataFolder: nil),
            settings: settings)
        window.hud = model.hud
        model.hud.attach(window: window)
        model.launch()
    }

    var pending: NotificationRequest? { notifier.pending[FocusStore.notificationID] }

    var delivered: NotificationRequest? { notifier.delivered[FocusStore.notificationID] }

    /// Time passes: macOS shows the notifications that are due, and HeadsUp's wake-ups fire.
    func minutes(_ count: Double) {
        notifier.deliverDue(at: clock.now.addingTimeInterval(count * 60))
        scheduler.advance(by: count * 60)
    }
}

@MainActor
@Suite struct FocusStoreTests {
    // MARK: A whole round

    @Test func startingAFocusToastsSchedulesTheNotificationAndAsksPermission() {
        let h = FocusHarness()
        h.focus.start()
        #expect(h.hud.footerLeft == .toast("Focus started · 25 min"))
        #expect(h.notifier.authorizationRequests == 1)
        #expect(h.pending?.category == .focusEnd)
        #expect(h.pending?.title == "Focus done · 25 min")
        #expect(h.pending?.body == "Time for a break.")
        #expect(h.pending?.date == h.clock.now.addingTimeInterval(25 * 60))
        #expect(h.model.tabActivity == [.focus: .active])
        #expect(h.focus.snapshot == .running(.focus, endsAt: h.clock.now.addingTimeInterval(25 * 60)))
    }

    @Test func aFocusThatEndsCountsTheSessionAndOpensTheHUDWithoutKey() {
        let h = FocusHarness()
        h.focus.start(minutes: 40)
        h.minutes(40)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(h.focus.today == FocusDay(sessions: 1, minutes: 40))
        #expect(h.hud.isOpen && !h.hud.isKey)
        #expect(h.hud.tab == .focus)
        // On Focus the prompt is seen; closed, the item turns orange.
        #expect(h.model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: false)])
        h.hud.close()
        #expect(h.model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: true)])
    }

    @Test func withTheSettingOffOnlyTheNotificationTellsTheUser() {
        var settings = Settings()
        settings.focus.openHudOnEnd = false
        let h = FocusHarness(settings: settings)
        h.focus.start()
        h.minutes(25)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(!h.hud.isOpen)
    }

    @Test func aBreakRunsAndBringsTheBackPrompt() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.focus.selectActivity("look")
        #expect(h.focus.breakLength == 2)
        h.focus.setBreakLength(10)
        h.focus.startBreak()
        #expect(h.hud.footerLeft == .toast("Break started · 10 min"))
        #expect(h.pending?.category == .breakEnd)
        #expect(h.pending?.title == "Break over")
        #expect(h.pending?.body == "Ready to get back to it?")
        h.hud.close()
        h.minutes(10)
        #expect(h.focus.phase == .prompt(.backPrompt))
        #expect(h.hud.isOpen && h.hud.tab == .focus)
        #expect(h.pending == nil)
    }

    @Test func withAutoStartTheNextFocusStartsAndTheNotificationSaysSo() {
        let h = FocusHarness()
        h.focus.setAutoStartNextFocus(true)
        h.focus.start()
        h.minutes(25)
        h.focus.startBreak()
        #expect(h.pending?.category == .breakAutostart)
        #expect(h.pending?.body == "Focus started · 25 min")
        h.hud.close()
        h.minutes(5)
        #expect(h.focus.snapshot == .running(.focus, endsAt: h.clock.now.addingTimeInterval(25 * 60)))
        #expect(!h.hud.isOpen)
        #expect(h.hud.footerLeft == .toast("Focus started · 25 min"))
        #expect(h.pending?.category == .focusEnd)
    }

    @Test func changingAutoStartDuringABreakReschedulesItsNotification() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        h.focus.startBreak()
        #expect(h.pending?.category == .breakEnd)
        h.focus.setAutoStartNextFocus(true)
        #expect(h.pending?.category == .breakAutostart)
    }

    // MARK: Pause, stop, snooze

    @Test func pauseCancelsTheNotificationAndTheWakeUpAndResumeBringsThemBack() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(10)
        h.focus.pause()
        #expect(h.pending == nil)
        #expect(h.scheduler.pendingCount <= 1)  // at most the toast's own timer
        h.minutes(60)
        #expect(h.focus.snapshot == .paused(.focus, left: 15 * 60))
        h.focus.resume()
        #expect(h.pending?.date == h.clock.now.addingTimeInterval(15 * 60))
        h.minutes(15)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
    }

    @Test func stopGoesIdleAndCancelsTheNotification() {
        let h = FocusHarness()
        h.focus.start()
        h.focus.stop()
        #expect(h.focus.phase == .idle)
        #expect(h.pending == nil)
        #expect(h.model.tabActivity.isEmpty)
        h.minutes(30)
        #expect(h.focus.today == FocusDay())
    }

    @Test func snoozeToastsHidesTheHUDAndBringsThePromptBack() {
        var settings = Settings()
        settings.focus.snoozeMinutes = 2
        let h = FocusHarness(settings: settings)
        h.focus.start()
        h.minutes(25)
        h.hud.open(tab: .focus)  // the user clicked it
        h.focus.snooze()
        #expect(h.hud.footerLeft == .toast("Snoozed for 2 min"))
        #expect(h.hud.isOpen)
        h.scheduler.advance(by: 0.6)
        #expect(!h.hud.isOpen)
        #expect(h.model.statusItem.parts == [.appGlyph])  // a snoozed timer shows nothing
        #expect(h.model.tabActivity == [.focus: .active])
        h.minutes(2)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(h.hud.isOpen && h.hud.tab == .focus)
    }

    // MARK: Notifications

    @Test func startBreakFromNotificationCenter() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.model.handleNotification(category: "focus.end", action: "start-break")
        #expect(h.focus.snapshot == .running(.rest, endsAt: h.clock.now.addingTimeInterval(5 * 60)))
    }

    @Test func aNotificationAnsweredAfterSleepFirstCatchesUp() {
        let h = FocusHarness()
        h.focus.start()
        // The Mac slept through the end: no wake-up fired, the clock moved on.
        h.clock.advance(by: 30 * 60)
        h.model.handleNotification(category: "focus.end", action: "snooze")
        #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(5 * 60)))
        #expect(h.focus.today.sessions == 1)
    }

    @Test func startFocusAndStopFromNotificationCenter() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        h.model.handleNotification(category: "break.end", action: "start-focus")
        #expect(h.focus.snapshot == .running(.focus, endsAt: h.clock.now.addingTimeInterval(25 * 60)))
        h.model.handleNotification(category: "break.autostart", action: "stop")
        #expect(h.focus.phase == .idle)
    }

    @Test func oldOrUnknownAnswersDoNothing() {
        let h = FocusHarness()
        h.model.handleNotification(category: "focus.end", action: "start-break")  // idle: nothing to break from
        #expect(h.focus.phase == .idle)
        h.model.handleNotification(category: "focus.end", action: "stop")  // not an action of this category
        h.model.handleNotification(category: "service.failed", action: nil)
        h.model.handleNotification(category: "focus.end", action: "rm -rf")
        #expect(h.focus.phase == .idle)
        #expect(!h.hud.isOpen)
    }

    @Test func clickingTheBodyOpensTheHUDOnFocus() {
        let h = FocusHarness()
        h.model.handleNotification(category: "break.end", action: nil)
        #expect(h.hud.isOpen && h.hud.isKey && h.hud.tab == .focus)
    }

    // MARK: Sleep, days

    @Test func afterWakeTheEndHappensAtOnce() {
        let h = FocusHarness()
        h.focus.start()
        h.clock.advance(by: 3 * 3600)
        h.model.clockJumped()
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(h.hud.isOpen)
    }

    @Test func todaysStatsResetAtLocalMidnight() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        #expect(h.focus.today.sessions == 1)
        h.clock.advance(by: 86_400)
        #expect(h.focus.today == FocusDay())
    }

    // MARK: Settings → Focus

    @Test func theLastBreakOptionCantBeRemoved() {
        let h = FocusHarness()
        for option in BreakOption.defaults { h.focus.removeBreakOption(option.id) }
        #expect(h.model.settings.settings.focus.breakOptions.map(\.id) == ["lunch"])
        #expect(h.focus.activity.id == "lunch")
    }

    @Test func anOptionLengthCyclesThroughTheAllowedLengths() {
        let h = FocusHarness()
        var lengths: [Int] = []
        for _ in 0..<5 {
            h.focus.cycleBreakOptionLength("look")
            lengths.append(h.model.settings.settings.focus.breakOptions[0].length)
        }
        #expect(lengths == [5, 10, 20, 50, 2])
    }

    @Test func addingAnOptionNeedsALabelAndGetsTheDot() {
        let h = FocusHarness()
        h.focus.addBreakOption(label: "   ", minutes: 5)
        #expect(h.model.settings.settings.focus.breakOptions.count == 5)
        h.focus.addBreakOption(label: "Walk around the block", minutes: 20)
        let added = h.model.settings.settings.focus.breakOptions.last
        #expect(added?.label == "Walk around the block")
        #expect(added?.icon == .dot)
        #expect(added?.length == 20)
    }

    @Test func lengthsOutsideTheirSetsAreRefused() {
        let h = FocusHarness()
        h.focus.setFocusLength(33)
        h.focus.setSnoozeMinutes(7)
        h.focus.setBreakLength(3)
        #expect(h.focus.focusLength == 25)
        #expect(h.model.settings.settings.focus.snoozeMinutes == 5)
        #expect(h.focus.breakLength == 5)
        h.focus.setFocusLength(50)
        #expect(h.focus.focusLength == 50)
        #expect(h.focus.snapshot == .idle(nextLength: 50))
    }

    @Test func aBrokenFocusSectionDecodesToTheRules() throws {
        let json = #"{ "focus": { "focusLength": 33, "snoozeMinutes": 2, "breakOptions": [] } }"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.focus.focusLength == 25)
        #expect(settings.focus.snoozeMinutes == 2)
        #expect(settings.focus.breakOptions == BreakOption.defaults)
    }

    // MARK: Actions and pill

    @Test func theStopActionShowsOnlyWhileATimerRuns() {
        let h = FocusHarness()
        #expect(!h.model.registry.actions.contains { $0.id == ActionID("focus.stop") })
        h.focus.start()
        let stop = h.model.registry.actions.first { $0.id == ActionID("focus.stop") }
        #expect(stop?.subtitle == "pomodoro · focus")
        stop?.run()
        #expect(h.focus.phase == .idle)
    }

    @Test func aStartActionStartsAndGoesToFocus() throws {
        let h = FocusHarness()
        let start = try #require(h.model.registry.actions.first { $0.id == ActionID("focus.start:50") })
        start.run()
        #expect(h.focus.snapshot == .running(.focus, endsAt: h.clock.now.addingTimeInterval(50 * 60)))
        #expect(h.hud.tab == .focus && h.hud.isOpen)
    }

    @Test func thePillCountsDown() {
        let h = FocusHarness()
        #expect(h.focus.pill(at: h.clock.now) == nil)
        h.focus.start()
        #expect(h.focus.pill(at: h.clock.now.addingTimeInterval(6 * 60 + 18)) == "Focus 18:42")
        h.minutes(25)
        h.focus.snooze()
        #expect(h.focus.pill(at: h.clock.now.addingTimeInterval(48)) == "Snoozed 4:12")
    }
}

/// The slice 3 review loop: delivered notifications, snoozed notifications, auto-open by HUD
/// state, the snooze hide, and rejected answers.
@MainActor
@Suite struct FocusReviewTests {
    // (a) Rev 1

    @Test func aDeliveredNotificationStaysUntilItsPromptIsAnswered() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        #expect(h.delivered?.category == .focusEnd)
        // Looking at the prompt and picking an activity isn't an answer.
        h.focus.selectActivity("look")
        #expect(h.delivered != nil)
        h.focus.startBreak()
        #expect(h.delivered == nil)
        #expect(h.pending?.category == .breakEnd)
    }

    @Test func aPendingNotificationGoesWithItsTimerButADeliveredOneDoesnt() {
        let h = FocusHarness()
        h.focus.start()
        h.focus.pause()
        #expect(h.pending == nil)
        h.focus.resume()
        h.minutes(25)
        h.focus.showNow()  // not snoozed: no change
        #expect(h.delivered != nil)
        h.focus.doneForNow()  // not a back prompt: no change
        #expect(h.delivered != nil)
        h.focus.takeBreakNow()  // the prompt gives way to a manual one
        #expect(h.delivered == nil)
    }

    // (b) Rev 2 / Nick 2

    @Test(arguments: [true, false])
    func aSnoozedBreakPromptIsNotifiedAgainAtTheSnoozeEnd(openHud: Bool) {
        var settings = Settings()
        settings.focus.openHudOnEnd = openHud
        let h = FocusHarness(settings: settings)
        h.focus.start(minutes: 40)
        h.minutes(40)
        h.model.handleNotification(category: "focus.end", action: "snooze")
        #expect(h.delivered == nil)
        #expect(h.pending?.category == .focusEnd)
        #expect(h.pending?.title == "Time for a break")
        #expect(h.pending?.body == "Snooze is over. Your 40 min focus is done.")
        #expect(h.pending?.date == h.clock.now.addingTimeInterval(5 * 60))
        h.minutes(5)
        #expect(h.delivered?.category == .focusEnd)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(h.hud.isOpen == openHud)
    }

    @Test(arguments: [true, false])
    func aSnoozedBackPromptIsNotifiedAgainAtTheSnoozeEnd(openHud: Bool) {
        var settings = Settings()
        settings.focus.openHudOnEnd = openHud
        let h = FocusHarness(settings: settings)
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        h.hud.close()
        h.model.handleNotification(category: "break.end", action: "snooze")
        #expect(h.pending?.category == .breakEnd)
        #expect(h.pending?.title == "Break over")
        #expect(h.pending?.body == "Snooze is over. Ready to get back to it?")
        h.minutes(5)
        #expect(h.delivered?.category == .breakEnd)
        #expect(h.hud.isOpen == openHud)
    }

    @Test func aSnoozedManualPromptHasNoSessionLengthToName() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        h.focus.snooze()
        #expect(h.pending?.title == "Time for a break")
        #expect(h.pending?.body == "Snooze is over.")
        #expect(h.pending?.category.actions == [.startBreak, .snooze])
    }

    @Test func aSnoozedPromptReturningToAnOpenHUDInUseToastsItsTitle() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.focus.snooze()
        h.scheduler.advance(by: 1)  // the HUD hides
        h.hud.open(tab: .chat)
        h.minutes(5)
        #expect(h.hud.tab == .chat)
        #expect(h.hud.footerLeft == .toast("Time for a break"))
    }

    // (c) Yuki / Nick: auto-open by the HUD's state

    @Test func aClosedHUDOpensOnFocusCleanAndWithoutKey() {
        let h = FocusHarness()
        h.focus.start()
        h.hud.open(tab: .chat)
        h.hud.setInput("half a sentence")
        h.hud.toggleModelMenu()
        h.hud.close()
        h.minutes(25)
        #expect(h.hud.isOpen && !h.hud.isKey)
        #expect(h.hud.tab == .focus)
        #expect(h.hud.input == "")
        #expect(!h.hud.modelMenuOpen)
    }

    @Test func anOpenKeyHUDStaysAndToasts() {
        let h = FocusHarness()
        h.focus.start()
        h.hud.open(tab: .chat)
        h.hud.setInput("a question I'm typing")
        h.minutes(25)
        #expect(h.hud.isOpen && h.hud.isKey)
        #expect(h.hud.tab == .chat)
        #expect(h.hud.input == "a question I'm typing")
        #expect(h.hud.footerLeft == .toast("Focus done · time for a break"))
        // Not orange while the HUD stays open; orange once it closes without an answer.
        #expect(h.model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: false)])
        h.hud.close()
        #expect(h.model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: true)])
    }

    @Test func anOpenHUDWithoutKeySwitchesToFocusAndKeepsTheText() {
        var settings = Settings()
        settings.general.closeOnClickOutside = false
        let h = FocusHarness(settings: settings)
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.hud.open(tab: .services)
        h.hud.setInput("ssh")
        h.window.clickElsewhere()
        h.minutes(5)
        #expect(h.hud.isOpen && !h.hud.isKey)
        #expect(h.hud.tab == .focus)
        #expect(h.hud.input == "ssh")
    }

    @Test func anHUDAlreadyOnFocusShowsThePromptInPlace() {
        let h = FocusHarness()
        h.focus.start()
        h.hud.open(tab: .focus)
        h.minutes(25)
        #expect(h.hud.isOpen && h.hud.isKey && h.hud.tab == .focus)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.otherTab))
    }

    // (d) the snooze hide

    @Test func usingTheHUDAfterSnoozeKeepsItOpen() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.hud.open(tab: .focus)
        h.focus.snooze()
        h.hud.selectTab(.chat)
        h.scheduler.advance(by: 1)
        #expect(h.hud.isOpen)

        h.focus.showNow()
        h.focus.snooze()
        h.focus.showNow()  // a Focus intent
        h.scheduler.advance(by: 1)
        #expect(h.hud.isOpen)
    }

    // (h) Scan L1: rejected answers

    @Test func stopFromAnAutoStartNotificationDoesNothingAtAPrompt() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        h.model.handleNotification(category: "break.autostart", action: "stop")
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: true)))
    }

    @Test func startBreakWhileIdleOrAnUnknownAnswerDoesNothing() {
        let h = FocusHarness()
        h.model.handleNotification(category: "focus.end", action: "start-break")
        h.model.handleNotification(category: "focus.ending", action: "snooze")
        h.model.handleNotification(category: "break.end", action: "start-focus; rm")
        h.model.handleNotification(category: "break.end", action: "")
        #expect(h.focus.phase == .idle)
        #expect(h.pending == nil)
        #expect(!h.hud.isOpen)
    }
}

/// Nick's display models for the Focus views (slice 3 contract).
@MainActor
@Suite struct FocusScreenTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test func idleShowsTheSelectedLengthAndTodaysStats() {
        let h = FocusHarness()
        guard case .idle(let idle) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected idle")
            return
        }
        #expect(idle.label == "Focus session")
        #expect(idle.timer == "25:00")
        #expect(idle.today == "0 sessions · 0m focused today")
        #expect(idle.lengths.map(\.title) == ["25 min", "40 min", "50 min"])
        #expect(idle.lengths.map(\.hint) == ["Classic pomodoro", "Steady block", "Deep work"])
        #expect(idle.lengths.map(\.isSelected) == [true, false, false])
        #expect(idle.breaksOffer == "Breaks offer: look elsewhere, drink water, stretch your arms…")
        #expect(idle.start == "Start focus")
    }

    @Test func aRunningFocusSaysWhenTheBreakComesInTheUsersClock() {
        let h = FocusHarness()
        h.focus.start()
        let start = h.clock.now
        let us = h.focus.screen(at: start.addingTimeInterval(60), locale: Locale(identifier: "en_US"), timeZone: utc)
        let gb = h.focus.screen(at: start.addingTimeInterval(60), locale: Locale(identifier: "en_GB"), timeZone: utc)
        guard case .running(let running) = us, case .running(let british) = gb else {
            Issue.record("expected running")
            return
        }
        let endsAt = start.addingTimeInterval(25 * 60)
        let expectedUS = FocusStore.clockTime(endsAt, locale: Locale(identifier: "en_US"), timeZone: utc)
        let expectedGB = FocusStore.clockTime(endsAt, locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(expectedUS.contains("AM") || expectedUS.contains("PM"))
        #expect(!expectedGB.contains("AM") && !expectedGB.contains("PM"))
        #expect(running.label == "Focusing")
        #expect(running.timer == "24:00")
        #expect(running.timerAccessibility == "24 minutes left")
        #expect(running.subtitle == "25 min session · break at \(expectedUS)")
        #expect(british.subtitle == "25 min session · break at \(expectedGB)")
        #expect(running.stopTitle == "Stop")
        #expect(running.pauseTitle == "Pause" && running.pauseGlyph == .pause)
        #expect(abs(running.progress - 1.0 / 25) < 1e-9)
    }

    @Test func pausedAndBreakTitles() {
        let h = FocusHarness()
        h.focus.start()
        h.focus.togglePause()
        guard case .running(let paused) = h.focus.screen(at: h.clock.now) else { return }
        #expect(paused.label == "Focus · paused")
        #expect(paused.pauseTitle == "Resume" && paused.pauseGlyph == .play)
        h.focus.togglePause()
        #expect(h.focus.snapshot == .running(.focus, endsAt: h.clock.now.addingTimeInterval(25 * 60)))

        h.focus.takeBreakNow()
        h.focus.startBreak()
        guard case .running(let rest) = h.focus.screen(at: h.clock.now) else { return }
        #expect(rest.label == "Break · Drink water")
        #expect(rest.subtitle == "Step away. The HUD will call you back.")
        #expect(rest.stopTitle == "End break")
        h.focus.stopRun()
        #expect(h.focus.phase == .prompt(.backPrompt))
    }

    @Test func anAutomaticBreakPromptOffersKeepWorkingAndAManualOneDoesnt() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        guard case .breakPrompt(let automatic) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the break prompt")
            return
        }
        #expect(automatic.label == "25 min session done · 1 today")
        #expect(automatic.title == "Time for a break")
        #expect(automatic.keepWorking == "Keep working")
        #expect(automatic.options.first { $0.isSelected }?.id == "water")
        #expect(automatic.options.map(\.length).first == "2 min")
        #expect(automatic.lengths.map(\.minutes) == [2, 5, 10, 20, 50])
        #expect(automatic.lengths.first { $0.isSelected }?.minutes == 5)
        #expect(automatic.selectedLength == 5)
        h.focus.setBreakLength(20)
        if case .breakPrompt(let changed) = h.focus.screen(at: h.clock.now) { #expect(changed.selectedLength == 20) }
        h.focus.setBreakLength(5)
        #expect(automatic.snooze == "Snooze 5 min")
        #expect(automatic.startBreak == "Start 5 min break")

        h.focus.takeBreakNow()
        guard case .breakPrompt(let manual) = h.focus.screen(at: h.clock.now) else { return }
        #expect(manual.keepWorking == nil)
        #expect(manual.label == "1 session · 25m focused today")
    }

    @Test func theBackPromptAndSnoozedScreens() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        guard case .backPrompt(let back) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the back prompt")
            return
        }
        #expect(back.label == "Break finished")
        #expect(back.title == "Ready to get back to it?")
        #expect(back.start == "Start 25 min focus")
        h.focus.snooze()
        guard case .snoozed(let snoozed) = h.focus.screen(at: h.clock.now.addingTimeInterval(48)) else { return }
        #expect(snoozed.title == "Prompt returns in 4:12")
        #expect(snoozed.showNow == "Show now")
    }

    @Test func settingsScreenAndItsRules() {
        let h = FocusHarness()
        let screen = h.focus.settingsScreen
        #expect(screen.focusLength == 25)
        #expect(screen.options.map(\.length) == ["2m", "5m", "5m", "10m", "50m"])
        #expect(screen.options.allSatisfy { $0.canRemove })
        #expect(!FocusStore.canAddBreakOption(label: "  "))
        #expect(FocusStore.canAddBreakOption(label: "Walk"))
        for option in BreakOption.defaults.dropLast() { h.focus.removeBreakOption(option.id) }
        #expect(!h.focus.canRemoveBreakOption)
        #expect(h.focus.settingsScreen.options.map(\.canRemove) == [false])
    }
}

@MainActor
@Suite struct FocusCopyAdditionsTests {
    @Test func aManualPromptBeforeAnySessionSaysSo() {
        let h = FocusHarness()
        h.focus.takeBreakNow()
        guard case .breakPrompt(let prompt) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the break prompt")
            return
        }
        #expect(prompt.label == "No sessions yet today")
    }

    @Test func aNewOptionStartsAtFiveMinutes() {
        let h = FocusHarness()
        #expect(FocusSettings.newOptionLength == 5)
        h.focus.addBreakOption(label: "Walk")
        #expect(h.model.settings.settings.focus.breakOptions.last?.length == 5)
    }
}

@MainActor
@Suite struct FocusBodyTests {
    @Test func theFocusTabShowsItsBodyAndTypingShowsSuggestionsInstead() {
        let model = AppModel.preview()
        model.hud.selectTab(.focus)
        #expect(model.body == .focus)
        model.hud.setInput("theme")
        #expect(model.body == .suggestions)
        model.hud.setInput("")
        #expect(model.body == .focus)
    }
}
