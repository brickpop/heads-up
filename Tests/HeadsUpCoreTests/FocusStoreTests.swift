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
                imageProcessor: FakeImageProcessor(), calendar: FakeCalendarReader(), reminders: FakeRemindersAccess(),
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
        h.focus.endBreak()  // not a break: no change
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
        #expect(h.pending?.category.actions == [.startBreak, .snooze, .done])
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
        #expect(h.hud.footerLeft == .hints(Strings.Hints.otherTabEmpty))
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
        #expect(
            idle.lengths.map(\.accessibilityLabel) == [
                "25 min, Classic pomodoro, selected", "40 min, Steady block", "50 min, Deep work",
            ])
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
        #expect(running.stopIsDestructive)  // the session would be lost
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
        #expect(!rest.stopIsDestructive)  // it only moves on to the back prompt
        h.focus.stopRun()
        #expect(h.focus.phase == .prompt(.backPrompt))
    }

    @Test func bothBreakPromptsOfferDone() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        guard case .breakPrompt(let automatic) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the break prompt")
            return
        }
        #expect(automatic.label == "25 min session done · 1 today")
        #expect(automatic.title == "Time for a break")
        #expect(automatic.stopForNow == "Stop for now")
        #expect(automatic.options.first { $0.isSelected }?.id == "water")
        #expect(
            automatic.options.prefix(2).map(\.accessibilityLabel) == [
                "Look elsewhere, 2 min", "Drink water, 5 min, selected",
            ])
        #expect(automatic.options.map(\.length).first == "2 min")
        #expect(automatic.lengths.map(\.minutes) == [2, 5, 10, 20, 50])
        #expect(automatic.lengths.first { $0.isSelected }?.minutes == 5)
        #expect(automatic.selectedLength == 5)
        h.focus.setBreakLength(20)
        if case .breakPrompt(let changed) = h.focus.screen(at: h.clock.now) { #expect(changed.selectedLength == 20) }
        h.focus.setBreakLength(5)
        #expect(automatic.snooze.choices.first { $0.isSelected }?.minutes == 5)
        #expect(automatic.startBreak == "Start 5 min break")

        h.focus.takeBreakNow()
        guard case .breakPrompt(let manual) = h.focus.screen(at: h.clock.now) else { return }
        #expect(manual.stopForNow == "Stop for now")
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
        #expect(back.stopForNow == "Stop for now")
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

/// The loop from the keyboard, with the prompt field focused (CEO, 2026-10-29).
@MainActor
@Suite(.serialized) struct FocusLoopKeysTests {
    private let optionLeft = Shortcut(keyCode: KeyCode.leftArrow, modifiers: .option, key: "←")
    private let optionRight = Shortcut(keyCode: KeyCode.rightArrow, modifiers: .option, key: "→")
    private let commandReturn = Shortcut(keyCode: KeyCode.returnKey, modifiers: .command, key: "↩")

    @Test func optionArrowsPickAFocusLengthAndStopAtTheEnds() {
        let h = FocusHarness()
        h.hud.selectTab(.focus)
        #expect(h.model.handleShortcut(optionRight))
        #expect(h.focus.focusLength == 40)
        #expect(h.model.handleShortcut(optionRight))
        #expect(h.model.handleShortcut(optionRight))  // at the end: handled, no change
        #expect(h.focus.focusLength == 50)
        #expect(h.focus.cardMoves == 2)
        #expect(h.model.handleShortcut(optionLeft))
        #expect(h.focus.focusLength == 40)
    }

    @Test func optionArrowsPickABreakOptionAndItsLength() {
        let h = FocusHarness()
        h.hud.selectTab(.focus)
        h.focus.start()
        h.minutes(25)
        #expect(h.focus.activity.id == "water")
        #expect(h.model.handleShortcut(optionLeft))
        #expect(h.focus.activity.id == "look")
        #expect(h.focus.breakLength == 2)
        #expect(h.model.handleShortcut(optionLeft))
        #expect(h.focus.activity.id == "look")
    }

    @Test func withTextInThePromptOptionArrowsMoveByWord() {
        let h = FocusHarness()
        h.hud.selectTab(.focus)
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(optionRight))
        #expect(h.focus.focusLength == 25)
    }

    @Test func theKeysBelongToTheFocusViewOnly() {
        let h = FocusHarness()
        h.hud.selectTab(.chat)
        #expect(!h.model.handleShortcut(optionRight))
        #expect(!h.model.handleShortcut(commandReturn))
        #expect(h.focus.phase == .idle && h.focus.focusLength == 25)
    }

    @Test func commandReturnRunsThePrimaryButton() {
        let h = FocusHarness()
        h.hud.selectTab(.focus)
        #expect(h.model.handleShortcut(commandReturn))  // idle: Start focus
        guard case .focus = h.focus.phase else {
            Issue.record("expected a focus")
            return
        }
        #expect(!h.model.handleShortcut(commandReturn))  // running: nothing
        h.minutes(25)
        #expect(h.model.handleShortcut(commandReturn))  // break prompt: Start break
        guard case .rest(let run, "water") = h.focus.phase else {
            Issue.record("expected the break")
            return
        }
        #expect(run.minutes == 5)
        h.minutes(5)
        h.focus.snooze()
        #expect(h.model.handleShortcut(commandReturn))  // snoozed: Show now
        #expect(h.focus.phase == .prompt(.backPrompt))
        #expect(h.model.handleShortcut(Shortcut(keyCode: KeyCode.keypadEnter, modifiers: .command, key: "⌅")))
        guard case .focus = h.focus.phase else {
            Issue.record("expected a focus from the back prompt")
            return
        }
    }

    @Test func doneFromANotificationEndsTheLoop() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        #expect(h.delivered?.category.actions == [.startBreak, .snooze, .done])
        h.model.handleNotification(category: "focus.end", action: "done")
        #expect(h.focus.phase == .idle)
        #expect(h.delivered == nil)

        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        #expect(h.delivered?.category.actions == [.startFocus, .snooze, .done])
        h.model.handleNotification(category: "break.end", action: "done")
        #expect(h.focus.phase == .idle)
    }

    @Test func doneOnEitherPromptEndsTheLoop() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.focus.doneForNow()
        #expect(h.focus.phase == .idle)
        h.focus.takeBreakNow()
        h.focus.doneForNow()
        #expect(h.focus.phase == .idle)
    }

    @Test func theFooterShowsTheCardKeysWhileCardsShowAndThePromptIsEmpty() {
        let h = FocusHarness()
        let cards = FooterLeft.hints(Strings.Hints.focusCards)
        h.hud.selectTab(.focus)
        #expect(h.model.footerLeft == cards)  // idle
        #expect(
            cards
                == .hints([
                    Hint(keys: ["⌥←→"], label: "choose"), Hint(keys: ["⌘↩"], label: "start"),
                    Hint(keys: ["esc"], label: "close"),
                ]))
        h.hud.setInput("x")
        #expect(h.model.footerLeft != cards)
        h.hud.setInput("")

        h.focus.start()
        #expect(h.model.footerLeft == .toast("Focus started · 25 min"))  // a toast still wins
        h.minutes(1)
        #expect(h.model.footerLeft == .hints(Strings.Hints.otherTabEmpty))  // running
        h.minutes(24)
        #expect(h.model.footerLeft == .hints(Strings.Hints.focusPrompt))  // break prompt: esc snoozes
        h.focus.startBreak()
        h.minutes(5)
        #expect(h.model.footerLeft == .hints(Strings.Hints.focusPrompt))  // back prompt, with its cards
        h.focus.snooze()
        h.scheduler.advance(by: 3)
        #expect(h.model.footerLeft == .hints(Strings.Hints.otherTabEmpty))  // snoozed, once its toast is gone

        h.hud.selectTab(.chat)
        #expect(h.model.footerLeft == h.hud.footerLeft)
    }

    @Test func commandReturnCantBeTheWakeShortcut() {
        #expect(commandReturn.keysProblem == .usedByHeadsUp)
    }
}

/// After a start from the open HUD, it hides after `FocusStore.startHideDelay` (CEO, 2026-10-29).
@MainActor
@Suite(.serialized) struct FocusHideAfterStartTests {
    private let delay = FocusStore.startHideDelay

    @Test func startingFromTheHUDHidesItAfterTheDelay() {
        let h = FocusHarness()
        h.hud.open(tab: .focus)
        h.focus.start()
        #expect(h.hud.footerLeft == .toast("Focus started · 25 min"))
        h.scheduler.advance(by: delay - 0.1)
        #expect(h.hud.isOpen)
        h.scheduler.advance(by: 0.1)
        #expect(!h.hud.isOpen)

        h.minutes(25)
        h.hud.open(tab: .focus)
        #expect(h.model.handleShortcut(Shortcut(keyCode: KeyCode.returnKey, modifiers: .command, key: "↩")))
        guard case .rest = h.focus.phase else {
            Issue.record("expected the break")
            return
        }
        h.scheduler.advance(by: delay)
        #expect(!h.hud.isOpen)
    }

    // Card focus-end-auto-open: the CEO's run. A start from the HUD hides it; at the end it opens
    // by itself on the break prompt, without the keyboard, along with the notification.
    @Test func aStartThatHidTheHUDStillOpensItOnTheBreakPrompt() {
        let h = FocusHarness()
        h.hud.open(tab: .chat)
        h.hud.setInput("/start 1")
        h.hud.submit()
        h.scheduler.advance(by: delay)
        #expect(!h.hud.isOpen && !h.window.isVisible)
        let shown = h.window.showCount

        h.minutes(1)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
        #expect(h.delivered?.category == .focusEnd)
        #expect(h.hud.isOpen && h.hud.tab == .focus)
        #expect(h.window.isVisible && h.window.showCount == shown + 1 && !h.window.isKey)
    }

    @Test func aTypedStartHidesTheHUDToo() {
        let h = FocusHarness()
        h.hud.open(tab: .chat)
        h.hud.setInput("/start 30")
        h.hud.submit()
        guard case .focus(let run) = h.focus.phase else {
            Issue.record("expected a focus")
            return
        }
        #expect(run.minutes == 30)
        #expect(h.hud.isOpen && h.hud.tab == .focus)
        h.scheduler.advance(by: delay)
        #expect(!h.hud.isOpen)
    }

    @Test func doingSomethingInTheHUDKeepsItOpen() {
        let h = FocusHarness()
        h.hud.open(tab: .focus)
        h.focus.start()
        h.hud.setInput("n")  // typing
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)

        h.hud.setInput("")
        h.focus.stop()
        h.focus.start()
        h.hud.selectTab(.chat)  // a tab switch
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)
    }

    @Test func aStartFromTheToolOrANotificationDoesntHideTheHUD() {
        let h = FocusHarness()
        h.hud.open(tab: .chat)
        let tool: FocusControlling = h.focus
        _ = tool.start(minutes: 25)  // the chat's focus.timer tool
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)

        h.minutes(25)
        h.hud.open(tab: .chat)
        h.model.handleNotification(category: "focus.end", action: "start-break")
        guard case .rest = h.focus.phase else {
            Issue.record("expected the break")
            return
        }
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)

        h.minutes(5)  // the break ends: the back prompt
        h.hud.open(tab: .chat)
        h.model.handleNotification(category: "break.end", action: "start-focus")
        guard case .focus = h.focus.phase else {
            Issue.record("expected a focus")
            return
        }
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)
    }

    @Test func withVoiceOverOnAStartLeavesTheHUDOpen() {
        let h = FocusHarness()
        h.focus.isVoiceOverOn = { true }
        h.hud.open(tab: .focus)
        h.focus.start()
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)
    }

    @Test func aStartRightAfterSnoozeReplacesItsHide() {
        let h = FocusHarness()
        h.focus.start()
        h.minutes(25)
        h.hud.open(tab: .focus)
        let snoozeHide = FocusStore.hideAfterSnooze
        h.focus.snooze()  // would hide at snoozeHide
        h.scheduler.advance(by: snoozeHide - 0.01)
        h.focus.start()  // typed /start: hides `delay` from now
        h.scheduler.advance(by: 0.01)
        #expect(h.hud.isOpen)  // snoozeHide
        h.scheduler.advance(by: delay - 0.03)
        #expect(h.hud.isOpen)  // snoozeHide - 0.01 + delay - 0.02
        h.scheduler.advance(by: 0.02)
        #expect(!h.hud.isOpen)  // snoozeHide - 0.01 + delay
    }

    @Test func doneDoesntHideAndAClosedHUDIsntHiddenLater() {
        let h = FocusHarness()
        h.focus.start()  // the HUD is closed: nothing to hide
        h.hud.open(tab: .focus)
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen)

        h.minutes(25)
        h.focus.doneForNow()
        h.scheduler.advance(by: delay)
        #expect(h.hud.isOpen && h.focus.phase == .idle)
    }
}

/// ⌘← ⌘→ walk the tabs; ⌥← ⌥→ pick a Caffeine duration (CEO, 2026-10-29).
@MainActor
@Suite(.serialized) struct TabAndCaffeineKeysTests {
    private func key(_ keyCode: UInt32, _ modifiers: Shortcut.Modifiers) -> Shortcut {
        Shortcut(keyCode: keyCode, modifiers: modifiers, key: keyCode == KeyCode.leftArrow ? "←" : "→")
    }

    @Test func tabsStepInTheBarsOrderAndWrap() {
        #expect(Tab.chat.step(1) == .focus)
        #expect(Tab.settings.step(1) == .chat)
        #expect(Tab.chat.step(-1) == .settings)
        #expect(Tab.caffeine.step(-1) == .focus)
    }

    @Test func commandArrowsWalkTheTabsWhileThePromptIsEmpty() {
        let h = FocusHarness()
        h.hud.open(tab: .chat)
        var walked: [Tab] = []
        for _ in Tab.allCases {
            #expect(h.model.handleShortcut(key(KeyCode.rightArrow, .command)))
            walked.append(h.hud.tab)
        }
        #expect(walked == [.focus, .caffeine, .services, .commands, .settings, .chat])
        #expect(h.model.handleShortcut(key(KeyCode.leftArrow, .command)))
        #expect(h.hud.tab == .settings)
    }

    @Test func withTextCommandArrowsMoveInTheLine() {
        let h = FocusHarness()
        h.hud.open(tab: .focus)
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(key(KeyCode.leftArrow, .command)))
        #expect(!h.model.handleShortcut(key(KeyCode.rightArrow, .command)))
        #expect(h.hud.tab == .focus)
    }

    @Test func optionArrowsPickACaffeineDurationWithoutTurningItOn() {
        let h = FocusHarness()
        let caffeine = h.model.caffeine
        h.hud.open(tab: .caffeine)
        let start = caffeine.lastDuration
        let durations = CaffeineDuration.allCases
        let index = durations.firstIndex(of: start)!
        #expect(h.model.handleShortcut(key(KeyCode.rightArrow, .option)))
        #expect(caffeine.lastDuration == durations[min(index + 1, durations.count - 1)])
        #expect(!caffeine.isOn)  // off: the keyboard only picks; the switch turns it on

        for _ in durations { _ = h.model.handleShortcut(key(KeyCode.leftArrow, .option)) }
        #expect(caffeine.lastDuration == durations[0])  // stops at the start
        let moves = caffeine.cardMoves
        #expect(h.model.handleShortcut(key(KeyCode.leftArrow, .option)))
        #expect(caffeine.cardMoves == moves)  // nothing to announce at an end
        let screen = caffeine.screen(at: h.clock.now)
        #expect(screen.durations[0].accessibilityLabel == "15 min, selected")
        #expect(screen.durations[1].accessibilityLabel == "1 hour")
    }

    @Test func whileOnAKeyboardPickRestartsTheTimerWithIt() {
        let h = FocusHarness()
        let caffeine = h.model.caffeine
        h.hud.open(tab: .caffeine)
        caffeine.selectDuration(.fifteenMinutes)
        #expect(caffeine.isOn)
        h.scheduler.advance(by: 3)  // the toast goes
        #expect(h.model.handleShortcut(key(KeyCode.rightArrow, .option)))
        #expect(caffeine.isOn && caffeine.lastDuration == .oneHour)
        #expect(caffeine.endsAt == h.clock.now.addingTimeInterval(3600))
        #expect(h.hud.footerLeft != .toast(Strings.Caffeine.onByCard(.oneHour)))  // no toast, as a click while on
    }

    @Test func withTextOptionArrowsMoveByWordOnCaffeine() {
        let h = FocusHarness()
        h.hud.open(tab: .caffeine)
        let start = h.model.caffeine.lastDuration
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(key(KeyCode.rightArrow, .option)))
        #expect(h.model.caffeine.lastDuration == start)
    }

    @Test func theFooterNamesTheArrowKeysWhileThePromptIsEmpty() {
        let h = FocusHarness()
        h.hud.open(tab: .services)
        #expect(h.model.footerLeft == .hints(Strings.Hints.otherTabEmpty))
        #expect(
            Strings.Hints.otherTabEmpty == [
                Hint(keys: ["⌘←→"], label: "tabs"), Hint(keys: ["/"], label: "actions"),
                Hint(keys: ["esc"], label: "close"),
            ])
        h.hud.selectTab(.caffeine)
        #expect(h.model.footerLeft == .hints(Strings.Hints.caffeineOff))
        #expect(
            Strings.Hints.caffeineOff == [
                Hint(keys: ["⌥←→"], label: "choose"), Hint(keys: ["⌘↩"], label: "start"),
                Hint(keys: ["esc"], label: "close"),
            ])
        h.hud.selectTab(.focus)
        #expect(h.model.footerLeft == .hints(Strings.Hints.focusCards))  // Focus keeps its three
        h.hud.selectTab(.chat)
        #expect(h.model.footerLeft == .hints(Strings.Hints.chat))
    }

    @Test func commandArrowsCantBeTheWakeShortcut() {
        #expect(key(KeyCode.leftArrow, .command).keysProblem == .usedByHeadsUp)
        #expect(key(KeyCode.rightArrow, .command).keysProblem == .usedByHeadsUp)
    }
}

/// ⌘↩ on Caffeine is the header switch (CEO, 2026-10-29).
@MainActor
@Suite(.serialized) struct CaffeineCommandReturnTests {
    private let commandReturn = Shortcut(keyCode: KeyCode.returnKey, modifiers: .command, key: "↩")
    private let optionRight = Shortcut(keyCode: KeyCode.rightArrow, modifiers: .option, key: "→")

    @Test func commandReturnStartsWithTheSelectedDurationThenStops() {
        let h = FocusHarness()
        let caffeine = h.model.caffeine
        h.hud.open(tab: .caffeine)
        #expect(!caffeine.isOn)
        #expect(h.model.footerLeft == .hints(Strings.Hints.caffeineOff))
        #expect(h.model.handleShortcut(optionRight))
        let picked = caffeine.lastDuration
        #expect(h.model.handleShortcut(commandReturn))
        #expect(caffeine.isOn && caffeine.lastDuration == picked)
        #expect(caffeine.endsAt == picked.minutes.map { h.clock.now.addingTimeInterval(Double($0) * 60) })
        #expect(h.hud.footerLeft == .toast(Strings.Caffeine.onBySwitch))  // the switch's toast
        h.scheduler.advance(by: 3)  // the toast goes
        #expect(h.model.footerLeft == .hints(Strings.Hints.caffeineOn))
        #expect(
            Strings.Hints.caffeineOn == [
                Hint(keys: ["⌥←→"], label: "choose"), Hint(keys: ["⌘↩"], label: "stop"),
                Hint(keys: ["esc"], label: "close"),
            ])
        #expect(h.model.handleShortcut(commandReturn))
        #expect(!caffeine.isOn)
    }

    @Test func withTextTheKeyStaysThePrompts() {
        let h = FocusHarness()
        h.hud.open(tab: .caffeine)
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(commandReturn))
        #expect(!h.model.caffeine.isOn)
    }
}

/// Both prompts: pick the snooze length, esc snoozes for the default (snooze-choice, CEO,
/// 2026-10-30).
@MainActor
@Suite(.serialized) struct SnoozeChoiceTests {
    private let escape = Shortcut(keyCode: KeyNames.escape, modifiers: [], key: "esc")

    /// The break prompt, open on Focus, as after a click on the menu bar item.
    private func atBreakPrompt(snooze: Int = 5) -> FocusHarness {
        var settings = Settings()
        settings.focus.snoozeMinutes = snooze
        let h = FocusHarness(settings: settings)
        h.focus.start()
        h.minutes(25)
        h.hud.open(tab: .focus)
        return h
    }

    private func atBackPrompt() -> FocusHarness {
        let h = atBreakPrompt()
        h.focus.startBreak()
        h.minutes(5)
        h.hud.open(tab: .focus)
        return h
    }

    @Test(arguments: [2, 5, 10])
    func eachLengthSnoozesForThatLong(minutes: Int) {
        for h in [atBreakPrompt(), atBackPrompt()] {
            h.focus.snooze(minutes: minutes)
            #expect(h.hud.footerLeft == .toast("Snoozed for \(minutes) min"))
            #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(Double(minutes) * 60)))
            guard case .snoozed(let snoozed) = h.focus.screen(at: h.clock.now) else {
                Issue.record("expected the snoozed screen")
                continue
            }
            #expect(snoozed.title == "Prompt returns in \(minutes):00")
            h.scheduler.advance(by: 0.6)
            #expect(!h.hud.isOpen)  // hidden, as Snooze did
        }
    }

    @Test func aLengthOutsideTheChoicesDoesNothing() {
        let h = atBreakPrompt()
        h.focus.snooze(minutes: 7)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
    }

    @Test func theGroupShowsTheThreeLengthsWithTheSettingsDefault() {
        let h = atBreakPrompt(snooze: 10)
        guard case .breakPrompt(let prompt) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the break prompt")
            return
        }
        #expect(prompt.snooze.label == "Snooze")
        #expect(prompt.snooze.choices.map(\.title) == ["2m", "5m", "10m"])
        #expect(prompt.snooze.choices.map(\.isSelected) == [false, false, true])
        #expect(
            prompt.snooze.choices.map(\.accessibilityLabel) == [
                "Snooze, 2 minutes", "Snooze, 5 minutes", "Snooze, 10 minutes",
            ])
        h.focus.setSnoozeMinutes(2)  // Settings keeps setting it
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        guard case .backPrompt(let back) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the back prompt")
            return
        }
        #expect(back.snooze.choices.map(\.isSelected) == [true, false, false])
    }

    @Test func escOnAPromptSnoozesForTheDefault() {
        for h in [atBreakPrompt(snooze: 2), atBackPrompt()] {
            let minutes = h.model.settings.settings.focus.snoozeMinutes
            h.model.escape()
            #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(Double(minutes) * 60)))
            #expect(h.hud.isOpen)  // until the toast has shown
            h.scheduler.advance(by: 0.6)
            #expect(!h.hud.isOpen)
        }
    }

    @Test func escWithTextClearsItFirst() {
        let h = atBreakPrompt()
        h.hud.setInput("x")
        h.model.escape()
        #expect(h.hud.input.isEmpty)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))
    }

    @Test func escElsewhereStillCloses() {
        let h = atBreakPrompt()
        h.hud.selectTab(.chat)
        h.model.escape()
        #expect(!h.hud.isOpen)
        #expect(h.focus.phase == .prompt(.breakPrompt(manual: false)))

        let idle = FocusHarness()
        idle.hud.open(tab: .focus)
        idle.model.escape()
        #expect(!idle.hud.isOpen)
        #expect(idle.focus.phase == .idle)
    }

    @Test func theFooterSaysEscSnoozesOnThePrompts() {
        let snooze = FooterLeft.hints(Strings.Hints.focusPrompt)
        for h in [atBreakPrompt(), atBackPrompt()] {
            #expect(h.model.footerLeft == snooze)
            h.hud.selectTab(.services)
            #expect(h.model.footerLeft == .hints(Strings.Hints.otherTabEmpty))
        }
    }

    @Test func notificationsKeepOneSnoozeWithTheDefault() {
        let h = atBreakPrompt(snooze: 10)
        #expect(h.delivered?.category.actions == [.startBreak, .snooze, .done])
        h.model.handleNotification(category: "focus.end", action: "snooze")
        #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(10 * 60)))
    }
}

/// The back prompt's focus length cards, with the last focus's length selected (CEO,
/// 2026-10-30).
@MainActor
@Suite(.serialized) struct BackPromptLengthTests {
    private let optionLeft = Shortcut(keyCode: KeyCode.leftArrow, modifiers: .option, key: "←")
    private let optionRight = Shortcut(keyCode: KeyCode.rightArrow, modifiers: .option, key: "→")
    private let commandReturn = Shortcut(keyCode: KeyCode.returnKey, modifiers: .command, key: "↩")

    /// A focus of `minutes`, its break, and the back prompt, open on Focus.
    private func backPrompt(after minutes: Int) -> FocusHarness {
        let h = FocusHarness()
        h.focus.start(minutes: minutes)
        h.minutes(Double(minutes))
        h.focus.startBreak()
        h.minutes(5)
        h.hud.open(tab: .focus)
        return h
    }

    private func screen(_ h: FocusHarness) -> FocusScreen.BackPrompt? {
        guard case .backPrompt(let back) = h.focus.screen(at: h.clock.now) else {
            Issue.record("expected the back prompt")
            return nil
        }
        return back
    }

    @Test func thePresetOfTheLastFocusIsSelected() {
        let h = backPrompt(after: 40)
        guard let back = screen(h) else { return }
        #expect(back.lengths.map(\.minutes) == [25, 40, 50])
        #expect(back.lengths.map(\.isSelected) == [false, true, false])
        #expect(back.lengths[1].accessibilityLabel == "40 min, Steady block, selected")
        #expect(back.start == "Start 40 min focus")
        #expect(h.focus.focusLength == 25)  // Settings' default is left alone
    }

    @Test func aTypedLengthShowsAsAnExtraCardSelected() {
        let h = backPrompt(after: 35)
        guard let back = screen(h) else { return }
        #expect(back.lengths.map(\.minutes) == [25, 35, 40, 50])
        #expect(back.lengths.map(\.isSelected) == [false, true, false, false])
        #expect(back.lengths[1].title == "35 min")
        #expect(back.lengths[1].hint == "Last focus")
        #expect(back.start == "Start 35 min focus")
    }

    @Test func afterABreakStartedFromANotificationTheLastLengthIsSelected() {
        let h = FocusHarness()
        h.focus.start(minutes: 50)
        h.minutes(50)
        h.model.handleNotification(category: "focus.end", action: "start-break")
        h.minutes(5)
        guard let back = screen(h) else { return }
        #expect(back.lengths.first { $0.isSelected }?.minutes == 50)
        #expect(back.start == "Start 50 min focus")
    }

    @Test func withoutAFocusYetTheSettingsDefaultIsSelected() {
        let h = FocusHarness()
        h.focus.setFocusLength(40)
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        guard let back = screen(h) else { return }
        #expect(back.lengths.first { $0.isSelected }?.minutes == 40)
    }

    @Test func optionArrowsChangeTheSelectionAndTheButtonFollows() {
        let h = backPrompt(after: 35)
        #expect(h.model.footerLeft == .hints(Strings.Hints.focusPrompt))
        #expect(h.model.handleShortcut(optionRight))
        #expect(screen(h)?.start == "Start 40 min focus")
        #expect(h.model.handleShortcut(optionRight))
        #expect(h.model.handleShortcut(optionRight))  // at the end: handled, no change
        #expect(screen(h)?.lengths.last?.isSelected == true)
        #expect(h.focus.cardMoves == 2)
        #expect(h.model.handleShortcut(optionLeft))
        #expect(screen(h)?.start == "Start 40 min focus")
        #expect(screen(h)?.lengths.map(\.minutes) == [25, 35, 40, 50])  // the typed card stays
        #expect(h.focus.focusLength == 25)
    }

    @Test func withTextOptionArrowsMoveByWord() {
        let h = backPrompt(after: 40)
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(optionRight))
        #expect(screen(h)?.start == "Start 40 min focus")
    }

    @Test func commandReturnAndTheButtonStartTheSelectedLength() {
        let h = backPrompt(after: 35)
        h.focus.setNextFocusLength(50)
        #expect(h.model.handleShortcut(commandReturn))
        guard case .focus(let run) = h.focus.phase else {
            Issue.record("expected a focus")
            return
        }
        #expect(run.minutes == 50)
        #expect(h.focus.focusLength == 25)

        let clicked = backPrompt(after: 40)
        clicked.focus.start()  // the primary button
        guard case .focus(let clickedRun) = clicked.focus.phase else { return }
        #expect(clickedRun.minutes == 40)
    }

    @Test func aClickedCardIsSelected() {
        let h = backPrompt(after: 25)
        h.focus.setNextFocusLength(50)
        #expect(screen(h)?.start == "Start 50 min focus")
        h.focus.setNextFocusLength(35)  // not a card here: refused
        #expect(screen(h)?.start == "Start 50 min focus")
    }

    @Test func thePickSurvivesASnoozeButNotTheNextRound() {
        let h = backPrompt(after: 25)
        h.focus.setNextFocusLength(50)
        h.focus.snooze()
        h.focus.showNow()
        #expect(screen(h)?.start == "Start 50 min focus")
        h.focus.doneForNow()
        h.focus.takeBreakNow()
        h.focus.startBreak()
        h.minutes(5)
        #expect(screen(h)?.start == "Start 25 min focus")  // the last focus again
    }

    @Test func idleKeepsItsOwnCards() {
        let h = backPrompt(after: 35)
        h.focus.doneForNow()
        guard case .idle(let idle) = h.focus.screen(at: h.clock.now) else { return }
        #expect(idle.lengths.map(\.minutes) == [25, 40, 50])
        #expect(idle.lengths.first { $0.isSelected }?.minutes == 25)
    }

    @Test(arguments: [nil, 50])
    func startFocusFromTheNotificationStartsTheBackPromptsLength(pick: Int?) {
        let h = backPrompt(after: 35)
        if let pick { h.focus.setNextFocusLength(pick) }
        h.model.handleNotification(category: "break.end", action: "start-focus")
        guard case .focus(let run) = h.focus.phase else {
            Issue.record("expected a focus")
            return
        }
        #expect(run.minutes == (pick ?? 35))
        #expect(h.focus.focusLength == 25)
    }

    @Test func aBreakThatAutoStartsStartsTheLastFocusLength() {
        let h = FocusHarness()
        h.focus.setAutoStartNextFocus(true)
        h.focus.start(minutes: 35)  // typed /start 35
        h.minutes(35)
        h.focus.startBreak()
        #expect(h.pending?.category == .breakAutostart)
        #expect(h.pending?.body == "Focus started · 35 min")
        h.minutes(5)
        guard case .focus(let run) = h.focus.phase else {
            Issue.record("expected the next focus")
            return
        }
        #expect(run.minutes == 35)
        #expect(h.hud.footerLeft == .toast("Focus started · 35 min"))
        #expect(h.focus.focusLength == 25)
    }

    @Test func withoutAFocusYetAnAutoStartUsesTheSettingsLength() {
        let h = FocusHarness()
        h.focus.setAutoStartNextFocus(true)
        h.focus.setFocusLength(40)
        h.focus.takeBreakNow()
        h.focus.startBreak()
        #expect(h.pending?.body == "Focus started · 40 min")
        h.minutes(5)
        guard case .focus(let run) = h.focus.phase else {
            Issue.record("expected the next focus")
            return
        }
        #expect(run.minutes == 40)
    }
}

/// ⌥⇧←/→ picks the snooze length on both prompts, and esc snoozes for it (break-prompt-layout,
/// CEO, 2026-10-30).
@MainActor
@Suite(.serialized) struct SnoozeSelectionTests {
    private let optionShiftLeft = Shortcut(keyCode: KeyCode.leftArrow, modifiers: [.option, .shift], key: "←")
    private let optionShiftRight = Shortcut(keyCode: KeyCode.rightArrow, modifiers: [.option, .shift], key: "→")

    private func atBreakPrompt(snooze: Int = 5) -> FocusHarness {
        var settings = Settings()
        settings.focus.snoozeMinutes = snooze
        let h = FocusHarness(settings: settings)
        h.focus.start()
        h.minutes(25)
        h.hud.open(tab: .focus)
        return h
    }

    private func atBackPrompt() -> FocusHarness {
        let h = atBreakPrompt()
        h.focus.startBreak()
        h.minutes(5)
        h.hud.open(tab: .focus)
        return h
    }

    private func selected(_ h: FocusHarness) -> Int? {
        switch h.focus.screen(at: h.clock.now) {
        case .breakPrompt(let prompt): prompt.snooze.choices.first { $0.isSelected }?.minutes
        case .backPrompt(let prompt): prompt.snooze.choices.first { $0.isSelected }?.minutes
        default: nil
        }
    }

    @Test func theSelectionStartsAtTheSettingsDefault() {
        let h = atBreakPrompt(snooze: 10)
        #expect(selected(h) == 10)
        guard case .breakPrompt(let prompt) = h.focus.screen(at: h.clock.now) else { return }
        #expect(prompt.snooze.choices.map(\.isSelected) == [false, false, true])
    }

    @Test func optionShiftArrowsMoveItAndStopAtTheEnds() {
        for h in [atBreakPrompt(), atBackPrompt()] {
            #expect(h.model.handleShortcut(optionShiftRight))
            #expect(selected(h) == 10)
            #expect(h.model.handleShortcut(optionShiftRight))  // at the end: handled, no change
            #expect(selected(h) == 10)
            #expect(h.model.handleShortcut(optionShiftLeft))
            #expect(h.model.handleShortcut(optionShiftLeft))
            #expect(selected(h) == 2)
            #expect(h.focus.snoozeMoves == 3)  // VoiceOver hears each change, not the stop at the end
            #expect(h.model.settings.settings.focus.snoozeMinutes == 5)  // Settings doesn't change
        }
    }

    @Test func theBreakOptionKeysStayTheirs() {
        let h = atBreakPrompt()
        #expect(h.model.handleShortcut(Shortcut(keyCode: KeyCode.rightArrow, modifiers: .option, key: "→")))
        #expect(h.focus.activity.id == "stretch" && selected(h) == 5)
        #expect(h.model.handleShortcut(optionShiftRight))
        #expect(h.focus.activity.id == "stretch" && selected(h) == 10)
    }

    @Test func escSnoozesForTheSelectedLength() {
        for h in [atBreakPrompt(), atBackPrompt()] {
            _ = h.model.handleShortcut(optionShiftLeft)
            h.model.escape()
            #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(2 * 60)))
            #expect(h.hud.footerLeft == .toast("Snoozed for 2 min"))
        }
    }

    @Test func aClickStillSnoozesForItsOwnLength() {
        let h = atBreakPrompt()
        _ = h.model.handleShortcut(optionShiftLeft)
        h.focus.snooze(minutes: 10)
        #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(10 * 60)))
    }

    @Test func withTextTheKeysStayTheFields() {
        let h = atBreakPrompt()
        h.hud.setInput("x")
        #expect(!h.model.handleShortcut(optionShiftRight))
        #expect(selected(h) == 5)
    }

    @Test func onlyThePromptsHaveIt() {
        let h = FocusHarness()
        h.hud.open(tab: .focus)
        #expect(!h.model.handleShortcut(optionShiftRight))  // idle
        h.focus.start()
        #expect(!h.model.handleShortcut(optionShiftRight))  // running
        let prompt = atBreakPrompt()
        prompt.hud.selectTab(.chat)
        #expect(!prompt.model.handleShortcut(optionShiftRight))  // another tab
    }

    @Test func theNextPromptStartsAtTheDefaultAgain() {
        let h = atBreakPrompt()
        _ = h.model.handleShortcut(optionShiftRight)
        h.focus.snooze(minutes: 2)
        h.minutes(2)  // the prompt is back
        #expect(selected(h) == 5)
        _ = h.model.handleShortcut(optionShiftLeft)
        h.focus.startBreak()
        h.minutes(5)
        #expect(selected(h) == 5)  // the back prompt too
    }

    @Test func notificationsKeepSnoozingForTheDefault() {
        let h = atBreakPrompt()
        _ = h.model.handleShortcut(optionShiftRight)
        h.model.handleNotification(category: "focus.end", action: "snooze")
        #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(5 * 60)))
    }

    @Test func theGroupsArrowKeysSelectWithoutSnoozing() {
        let h = atBreakPrompt()
        h.focus.selectSnooze(10)
        #expect(selected(h) == 10 && h.focus.phase == .prompt(.breakPrompt(manual: false)))
        h.focus.selectSnooze(7)  // not a length: refused
        #expect(selected(h) == 10)
        h.model.escape()
        #expect(h.focus.snapshot == .snoozed(until: h.clock.now.addingTimeInterval(10 * 60)))
    }

    @Test func theNotificationsStopButtonIsStopForNow() {
        #expect(NotificationAction.done.title == "Stop for now")
    }

    @Test func theLengthGroupReadsAsBreakLength() {
        let h = atBreakPrompt()
        guard case .breakPrompt(let prompt) = h.focus.screen(at: h.clock.now) else { return }
        #expect(prompt.lengths.map(\.title) == ["2m", "5m", "10m", "20m", "50m"])
        #expect(prompt.lengths.map(\.accessibilityLabel).first == "2 minutes")
        #expect(Strings.Focus.lengthGroupAccessibility == "Break length")
    }
}
