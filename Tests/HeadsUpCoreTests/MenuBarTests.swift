import Foundation
import Testing

@testable import HeadsUpCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func status(
    _ focus: FocusSnapshot, _ caffeine: CaffeineSnapshot = .off, promptVisible: Bool = false, seconds: Bool = false
) -> StatusItemModel {
    StatusItemModel(focus: focus, caffeine: caffeine, now: now, promptVisible: promptVisible, showSeconds: seconds)
}

@Suite struct FormatTests {
    @Test func minutesForTheFocusTimerRoundUp() {
        #expect(Format.minutes(17 * 60 + 1, rounding: .up) == "18m")
        #expect(Format.minutes(18 * 60, rounding: .up) == "18m")
        #expect(Format.minutes(5, rounding: .up) == "1m")
    }

    @Test func minutesForCaffeineRoundToTheNearest() {
        #expect(Format.minutes(17 * 60 + 29, rounding: .nearest) == "17m")
        #expect(Format.minutes(17 * 60 + 30, rounding: .nearest) == "18m")
        #expect(Format.minutes(10, rounding: .nearest) == "1m")
    }

    @Test func anHourOrMoreShowsHoursAndTwoDigitMinutes() {
        #expect(Format.minutes(65 * 60, rounding: .nearest) == "1h 05m")
        #expect(Format.minutes(60 * 60, rounding: .up) == "1h 00m")
        #expect(Format.minutes(2 * 3600 + 13 * 60, rounding: .nearest) == "2h 13m")
    }

    @Test func clockShowsMinutesAndSecondsCountingUp() {
        #expect(Format.clock(18 * 60 + 42) == "18:42")
        #expect(Format.clock(3 * 60 + 9.2) == "3:10")
        #expect(Format.clock(0.4) == "0:01")
        #expect(Format.clock(-3) == "0:00")
        #expect(Format.clock(72 * 60) == "72:00")
    }

    @Test func spokenMinutes() {
        #expect(Format.spokenMinutes(18 * 60, rounding: .up) == "18 minutes")
        #expect(Format.spokenMinutes(60, rounding: .up) == "1 minute")
        #expect(Format.spokenMinutes(65 * 60, rounding: .nearest) == "1 hour 5 minutes")
        #expect(Format.spokenMinutes(120 * 60, rounding: .nearest) == "2 hours")
    }
}

@Suite struct StatusItemModelTests {
    @Test func idleShowsOnlyTheAppGlyph() {
        let model = status(.idle(nextLength: 25))
        #expect(model.parts == [.appGlyph])
        #expect(model.accessibilityLabel == "HeadsUp")
        #expect(model.nextChange == nil)
    }

    @Test func aRunningFocusShowsMinutesRoundedUp() {
        let model = status(.running(.focus, endsAt: now.addingTimeInterval(17 * 60 + 1)))
        #expect(model.parts == [.timer(glyph: .timer, text: "18m", warning: false)])
        #expect(model.accessibilityLabel == "HeadsUp, focus, 18 minutes left")
    }

    @Test func showSecondsUsesMinutesAndSecondsForFocus() {
        let model = status(.running(.rest, endsAt: now.addingTimeInterval(3 * 60 + 10)), seconds: true)
        #expect(model.parts == [.timer(glyph: .timer, text: "3:10", warning: false)])
    }

    @Test func caffeineShowsTheCupNextToTheTimerAndOnlyTheCupUntilOff() {
        let both = status(
            .running(.focus, endsAt: now.addingTimeInterval(600)), .on(endsAt: now.addingTimeInterval(65 * 60)))
        #expect(both.parts == [.timer(glyph: .timer, text: "10m", warning: false), .cup(text: "1h 05m", accent: true)])
        #expect(status(.idle(nextLength: 25), .on(endsAt: nil)).parts == [.cup(text: nil, accent: true)])
    }

    @Test func caffeineWithSecondsOnUsesMinutesAndSecondsOnlyUnderAnHour() {
        #expect(
            status(.idle(nextLength: 25), .on(endsAt: now.addingTimeInterval(59 * 60)), seconds: true).parts
                == [.cup(text: "59:00", accent: true)])
        #expect(
            status(.idle(nextLength: 25), .on(endsAt: now.addingTimeInterval(65 * 60)), seconds: true).parts
                == [.cup(text: "1h 05m", accent: true)])
    }

    @Test func pausedIsOrangeWithThePauseGlyphAndTheFrozenTime() {
        let model = status(.paused(.focus, left: 18 * 60))
        #expect(model.parts == [.timer(glyph: .pause, text: "18m", warning: true)])
        #expect(model.accessibilityLabel == "HeadsUp, focus paused, 18 minutes left")
        #expect(model.nextChange == nil)
        #expect(status(.paused(.rest, left: 90)).accessibilityLabel == "HeadsUp, break paused, 2 minutes left")
    }

    @Test func anUnansweredPromptIsOrangeWithWords() {
        let model = status(.prompt(.breakDue))
        #expect(model.parts == [.timer(glyph: .timer, text: "Break due", warning: true)])
        #expect(model.accessibilityLabel == "HeadsUp, break due")
        #expect(status(.prompt(.breakOver)).parts == [.timer(glyph: .timer, text: "Break over", warning: true)])
    }

    @Test func aPromptTheHUDShowsIsNotOrange() {
        #expect(
            status(.prompt(.breakDue), promptVisible: true).parts
                == [.timer(glyph: .timer, text: "Break due", warning: false)])
    }

    @Test func snoozedShowsNothingInTheMenuBar() {
        #expect(status(.snoozed(until: now.addingTimeInterval(300))).parts == [.appGlyph])
    }

    // MARK: Next change

    @Test func focusMinutesChangeAtTheNextMinuteBoundary() {
        // 17:01 left shows 18m until 17:00 left.
        let model = status(.running(.focus, endsAt: now.addingTimeInterval(17 * 60 + 1)))
        #expect(model.nextChange == now.addingTimeInterval(1))
        let exact = status(.running(.focus, endsAt: now.addingTimeInterval(18 * 60)))
        #expect(exact.nextChange == now.addingTimeInterval(60))
    }

    @Test func secondsChangeEverySecond() {
        let model = status(.running(.focus, endsAt: now.addingTimeInterval(100.25)), seconds: true)
        #expect(model.nextChange == now.addingTimeInterval(0.25))
    }

    @Test func caffeineMinutesChangeJustAfterEachHalfMinute() {
        // 17:40 left shows 18m; 17:30 still rounds up to 18m; just below it shows 17m.
        let tick = StatusItemModel.tick
        let model = status(.idle(nextLength: 25), .on(endsAt: now.addingTimeInterval(17 * 60 + 40)))
        #expect(model.nextChange == now.addingTimeInterval(10 + tick))
        // Exactly on a half minute, the change is one tick later, never now, never a minute late.
        let half = status(.idle(nextLength: 25), .on(endsAt: now.addingTimeInterval(17 * 60 + 30)))
        #expect(half.nextChange == now.addingTimeInterval(tick))
    }

    @Test func atEachRedrawTheCaffeineTextIsAlreadyTheNewMinute() {
        // Redraw at every nextChange from 3 minutes left: each text is one minute less.
        let endsAt = now.addingTimeInterval(3 * 60)
        var time = now
        var texts: [String] = []
        for _ in 0..<3 {
            let model = StatusItemModel(
                focus: .idle(nextLength: 25), caffeine: .on(endsAt: endsAt), now: time, promptVisible: false,
                showSeconds: false)
            if case .cup(let text?, _) = model.parts.first { texts.append(text) }
            guard let next = model.nextChange else { break }
            time = next
        }
        #expect(texts == ["3m", "2m", "1m"])
    }

    @Test func theEarliestChangeWins() {
        let model = status(
            .running(.focus, endsAt: now.addingTimeInterval(17 * 60 + 20)),
            .on(endsAt: now.addingTimeInterval(17 * 60 + 35)))
        #expect(model.nextChange == now.addingTimeInterval(5 + StatusItemModel.tick))
    }

    @Test func untilOffNeverChangesByItself() {
        #expect(status(.idle(nextLength: 25), .on(endsAt: nil)).nextChange == nil)
    }

    @Test func redrawingAtEachNextChangeAlwaysMovesForward() {
        // Walk a 3-minute caffeine and a 2-minute focus down to zero: every next change is later.
        var time = now
        let focusEnd = now.addingTimeInterval(120)
        let caffeineEnd = now.addingTimeInterval(180)
        var steps = 0
        while let next = StatusItemModel(
            focus: .running(.focus, endsAt: focusEnd), caffeine: .on(endsAt: caffeineEnd), now: time,
            promptVisible: false, showSeconds: false
        ).nextChange, next < caffeineEnd, steps < 100 {
            #expect(next > time)
            time = next
            steps += 1
        }
        #expect(steps < 100)
    }
}

@Suite struct MenuModelTests {
    private func focusRow(_ focus: FocusSnapshot) -> MenuRow? {
        let menu = MenuModel(
            hotkey: .ok(.wakeDefault), focus: focus, caffeine: .off, runningServices: 0, pinnedChats: 0, now: now)
        for case .row(let row) in menu.entries where row.action == .focus { return row }
        return nil
    }

    @Test func theRowsAreInTheSpecsOrder() {
        let menu = MenuModel(
            hotkey: .ok(.wakeDefault), focus: .idle(nextLength: 25), caffeine: .on(endsAt: nil), runningServices: 2,
            pinnedChats: 3, now: now)
        #expect(
            menu.entries == [
                .header(title: "HeadsUp", shortcut: "⌥ Space"),
                .row(MenuRow(action: .openHUD, title: "Open HUD", glyph: .chat)),
                .separator,
                .row(MenuRow(action: .focus, title: "Focus", glyph: .timer, value: "Start 25 min")),
                .row(MenuRow(action: .toggleCaffeine, title: "Caffeine", glyph: .cup, switchIsOn: true)),
                .row(MenuRow(action: .services, title: "Services", glyph: .servers, value: "2 running")),
                .separator,
                .row(MenuRow(action: .pinned, title: "Pinned chats", glyph: .pin, value: "3")),
                .row(MenuRow(action: .settings, title: "Settings…", glyph: .sliders, commandKey: ",")),
                .separator,
                .quit(title: "Quit HeadsUp"),
            ])
    }

    @Test func theHeaderShowsNoShortcutWhenItIsntRegistered() {
        let menu = MenuModel(
            hotkey: .taken, focus: .idle(nextLength: 25), caffeine: .off, runningServices: 0, pinnedChats: 0, now: now)
        #expect(menu.entries.first == .header(title: "HeadsUp", shortcut: nil))
    }

    @Test func theFocusRowFollowsTheDesign() {
        #expect(focusRow(.idle(nextLength: 50))?.value == "Start 50 min")
        #expect(focusRow(.running(.focus, endsAt: now.addingTimeInterval(18 * 60 + 42)))?.value == "Focus · 18:42")
        #expect(focusRow(.running(.rest, endsAt: now.addingTimeInterval(190)))?.value == "Break · 3:10")
        #expect(focusRow(.snoozed(until: now.addingTimeInterval(252)))?.value == "Snoozed · 4:12")

        let paused = focusRow(.paused(.focus, left: 18 * 60 + 42))
        #expect(paused?.value == "Paused · 18:42")
        #expect(paused?.valueIsWarning == true)
        #expect(focusRow(.prompt(.breakDue))?.value == "Break due")
        #expect(focusRow(.prompt(.breakOver))?.valueIsWarning == true)
        #expect(focusRow(.idle(nextLength: 25))?.valueIsWarning == false)
    }
}

@Suite struct ShortcutValidationTests {
    @Test func aShortcutNeedsCommandOptionOrControl() {
        #expect(Shortcut(keyCode: 40, modifiers: [], key: "K").keysProblem == .needsModifier)
        #expect(Shortcut(keyCode: 40, modifiers: .shift, key: "K").keysProblem == .needsModifier)
        #expect(Shortcut(keyCode: 40, modifiers: .command, key: "K").keysProblem == nil)
        #expect(Shortcut(keyCode: 49, modifiers: [.control, .shift], key: "Space").keysProblem == nil)
        #expect(Shortcut.wakeDefault.keysProblem == nil)
    }

    @Test func aFunctionKeyMayStandAlone() {
        #expect(Shortcut(keyCode: 96, modifiers: [], key: "F5").keysProblem == nil)
        #expect(Shortcut(keyCode: 96, modifiers: [.command], key: "F5").displayName == "⌘ F5")
    }

    @Test func keysThatTypeNoCharacterHaveNames() {
        #expect(KeyNames.name(49) == "Space")
        #expect(KeyNames.name(122) == "F1")
        #expect(KeyNames.name(126) == "↑")
        #expect(KeyNames.name(40) == nil)
    }
}

@MainActor
@Suite struct MenuBarAppModelTests {
    @Test func aPlainClickTogglesTheHUD() {
        let model = AppModel.preview()
        #expect(model.statusItem.parts == [.appGlyph])
        model.statusItemClicked()
        #expect(model.hud.isOpen)
        #expect(model.statusItemHighlighted)
        model.statusItemClicked()
        #expect(!model.hud.isOpen)
        #expect(!model.statusItemHighlighted)
    }

    @Test func anOrangeItemLeadsToFocus() {
        let model = AppModel.preview()
        model.focusSource = { .prompt(.breakDue) }
        #expect(model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: true)])

        model.statusItemClicked()  // closed → open on Focus
        #expect(model.hud.isOpen && model.hud.tab == .focus)
        // With the HUD open the prompt isn't dismissed: no longer orange, and a click closes.
        #expect(model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: false)])
        model.statusItemClicked()
        #expect(!model.hud.isOpen)

        // Open on another tab, a waiting prompt isn't orange either (Yuki, slice 3): a plain toggle.
        model.hud.open(tab: .chat)
        #expect(model.statusItem.parts == [.timer(glyph: .timer, text: "Break due", warning: false)])
        model.statusItemClicked()
        #expect(!model.hud.isOpen)
    }

    @Test func aPausedTimerClickAlsoLeadsToFocus() {
        let model = AppModel.preview()
        model.focusSource = { .paused(.focus, left: 600) }
        model.hud.open(tab: .services)
        model.statusItemClicked()
        #expect(model.hud.tab == .focus)
        #expect(model.hud.isOpen)
    }

    @Test func theMenuKeepsTheHUDOpenAndHighlightsTheItem() {
        let model = AppModel.preview()
        model.hud.open()
        model.menuWillOpen()
        #expect(model.statusItemHighlighted)
        #expect(model.hud.modalDepth == 1)
        model.menuDidClose()
        model.menuDidClose()  // a second close changes nothing
        #expect(model.hud.modalDepth == 0)
        #expect(model.hud.isOpen)
    }

    @Test func menuRowsGoWhereTheSpecSays() {
        let model = AppModel.preview()
        model.perform(.focus)
        #expect(model.hud.tab == .focus && model.hud.isOpen)
        model.perform(.services)
        #expect(model.hud.tab == .services)
        model.perform(.pinned)
        #expect(model.hud.tab == .chat && model.hud.chatView == .pinned)
        model.perform(.pinned)  // already there: stays on the list
        #expect(model.hud.chatView == .pinned)
        model.hud.selectSettingsSection(.general)
        model.perform(.settings)
        #expect(model.hud.tab == .settings && model.hud.settingsSection == .general)
        model.hud.close()
        model.perform(.openHUD)
        #expect(model.hud.isOpen && model.hud.tab == .settings)
    }

    @Test func theMenuHeaderShowsTheRegisteredShortcut() {
        #expect(AppModel.preview().menu.entries.first == .header(title: "HeadsUp", shortcut: "⌥ Space"))
        #expect(AppModel.preview(hotkey: .taken).menu.entries.first == .header(title: "HeadsUp", shortcut: nil))
    }

    @Test func showSecondsChangesTheItemText() {
        var settings = Settings()
        settings.general.menuSeconds = true
        let model = AppModel.preview(settings: settings)
        model.focusSource = { .paused(.focus, left: 18 * 60 + 42) }
        #expect(model.statusItem.parts == [.timer(glyph: .pause, text: "18:42", warning: true)])
    }
}

@MainActor
@Suite struct ShortcutLabelTests {
    @Test func aNewKeyboardLayoutRelabelsTheShortcutEverywhere() {
        var settings = Settings()
        settings.general.shortcut = Shortcut(keyCode: 12, modifiers: .option, key: "Q")
        let model = AppModel.preview(settings: settings)
        // On a French layout the same key types A.
        model.hud.shortcutLabelChanged("A")
        #expect(model.settings.settings.general.shortcut.key == "A")
        #expect(model.hud.hotkey == .ok(Shortcut(keyCode: 12, modifiers: .option, key: "A")))
        #expect(model.menu.entries.first == .header(title: "HeadsUp", shortcut: "⌥A"))
    }
}

@MainActor
@Suite struct WelcomeTests {
    @Test func theFirstLaunchOpensTheHUDWithTheWelcome() {
        let model = AppModel.preview(firstLaunch: true)
        #expect(model.hud.isOpen)
        #expect(model.hud.tab == .chat)
        #expect(model.showsWelcome)
        #expect(
            model.welcomeShortcutLine
                == "Press ⌥ Space in any app to open this. Press it again, or Esc, to hide it.")
    }

    @Test func laterLaunchesDont() {
        let model = AppModel.preview()
        #expect(!model.hud.isOpen)
        #expect(!model.showsWelcome)
    }

    @Test func escEndsTheWelcomeForGood() {
        let model = AppModel.preview(firstLaunch: true)
        model.hud.escape()
        #expect(!model.hud.isOpen)
        #expect(model.settings.settings.general.welcomeDone)
        model.hud.open(tab: .chat)
        #expect(!model.showsWelcome)
    }

    @Test func anotherTabEndsTheWelcome() {
        let model = AppModel.preview(firstLaunch: true)
        model.hud.selectTab(.focus)
        #expect(model.settings.settings.general.welcomeDone)
    }

    @Test func setUpAModelGoesToSettingsModelsAndEndsTheWelcome() {
        let model = AppModel.preview(firstLaunch: true)
        model.welcomeSetUpModel()
        #expect(model.hud.tab == .settings && model.hud.settingsSection == .models)
        #expect(model.settings.settings.general.welcomeDone)
    }

    @Test func theShortcutLineNamesTheRealShortcutOrAsksForOne() {
        var settings = Settings()
        settings.general.shortcut = Shortcut(keyCode: 40, modifiers: .command, key: "K")
        #expect(
            AppModel.preview(settings: settings, firstLaunch: true).welcomeShortcutLine.hasPrefix("Press ⌘K in any app")
        )
        #expect(
            AppModel.preview(hotkey: .taken, firstLaunch: true).welcomeShortcutLine
                == "Press your shortcut in any app to open this.")
    }

    @Test func theWelcomeProblemLineFollowsEachHotkeyState() {
        #expect(AppModel.preview(firstLaunch: true).welcomeProblemLine == nil)
        #expect(
            AppModel.preview(hotkey: .taken, firstLaunch: true).welcomeProblemLine
                == "⌥ Space is used by another app. Choose a shortcut:")
        #expect(
            AppModel.preview(hotkey: .reservedBySystem, firstLaunch: true).welcomeProblemLine
                == "⌥ Space is used by macOS. Choose a shortcut:")
        #expect(
            AppModel.preview(hotkey: .failed(-50), firstLaunch: true).welcomeProblemLine
                == "HeadsUp couldn't set up ⌥ Space. Choose a shortcut:")
    }
}

@MainActor
@Suite struct OpenAtLoginTests {
    struct Refused: Error {}

    @Test func itIsOffByDefaultAndTurnsOn() {
        let model = AppModel.preview()
        #expect(model.openAtLogin == .disabled)
        model.setOpenAtLogin(true)
        #expect(model.openAtLogin == .enabled)
        #expect(model.openAtLoginError == nil)
        model.setOpenAtLogin(false)
        #expect(model.openAtLogin == .disabled)
    }

    @Test func aFailureKeepsTheRealStatusAndSaysSo() {
        let model = AppModel.preview()
        let fake = FakeLoginItem()
        fake.failure = Refused()
        let failing = AppModel(
            ports: AppModel.Ports(
                clock: ManualClock(), scheduler: ManualScheduler(clock: ManualClock()),
                hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(), files: FakeFileRevealer(),
                loginItem: fake, systemSettings: FakeSystemSettingsLinks(), notifier: FakeNotifier(), dataFolder: nil))
        failing.setOpenAtLogin(true)
        #expect(failing.openAtLogin == .disabled)
        #expect(failing.openAtLoginError?.hasPrefix("HeadsUp couldn't change Open at Login") == true)
        #expect(model.openAtLoginError == nil)
    }

    @Test func approvalNeededIsReportedAndLeadsToLoginItems() {
        let links = FakeSystemSettingsLinks()
        let model = AppModel(
            ports: AppModel.Ports(
                clock: ManualClock(), scheduler: ManualScheduler(clock: ManualClock()),
                hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(), files: FakeFileRevealer(),
                loginItem: FakeLoginItem(status: .requiresApproval), systemSettings: links, notifier: FakeNotifier(),
                dataFolder: nil))
        #expect(model.openAtLogin == .requiresApproval)
        model.openLoginItemsSettings()
        model.openKeyboardShortcutsSettings()
        #expect(links.opened == ["loginItems", "keyboardShortcuts"])
    }
}

@MainActor
@Suite struct OpenAtLoginRefreshTests {
    @Test func goingToSettingsReadsTheStatusAgain() {
        let fake = FakeLoginItem()
        let model = AppModel(
            ports: AppModel.Ports(
                clock: ManualClock(), scheduler: ManualScheduler(clock: ManualClock()),
                hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(), files: FakeFileRevealer(),
                loginItem: fake, systemSettings: FakeSystemSettingsLinks(), notifier: FakeNotifier(), dataFolder: nil))
        try? fake.setEnabled(true)  // changed in System Settings
        #expect(model.openAtLogin == .disabled)
        model.hud.showSettings(.general)
        #expect(model.openAtLogin == .enabled)
    }
}

@MainActor
@Suite struct AmendmentFiveTests {
    @Test func headsUpsOwnShortcutsAreRefusedAfterTheModifierRule() {
        #expect(Shortcut(keyCode: KeyCode.digits[0], modifiers: .command, key: "1").keysProblem == .usedByHeadsUp)
        #expect(Shortcut(keyCode: KeyCode.comma, modifiers: .command, key: ",").keysProblem == .usedByHeadsUp)
        #expect(Shortcut(keyCode: KeyCode.q, modifiers: .command, key: "Q").keysProblem == .usedByHeadsUp)
        #expect(Shortcut(keyCode: KeyCode.period, modifiers: .command, key: ".").keysProblem == .usedByHeadsUp)
        // With another modifier they are free.
        #expect(Shortcut(keyCode: KeyCode.n, modifiers: [.command, .option], key: "N").keysProblem == nil)
        // A plain letter fails the first rule first.
        #expect(Shortcut(keyCode: KeyCode.n, modifiers: [], key: "N").keysProblem == .needsModifier)
    }

    @Test func theRecorderRefusesHeadsUpsOwnShortcut() {
        let model = AppModel.preview()
        model.hud.startRecording()
        model.hud.record(Shortcut(keyCode: KeyCode.n, modifiers: .command, key: "N"))
        #expect(model.hud.recording)
        #expect(model.hud.recorderProblem == "HeadsUp uses this shortcut. Choose another.")
        #expect(model.settings.settings.general.shortcut == .wakeDefault)
    }

    @Test func setUpAModelIsOneIntent() {
        let model = AppModel.preview(firstLaunch: true)
        model.welcomeSetUpModel()
        #expect(model.settings.settings.general.welcomeDone)
        #expect(model.hud.tab == .settings && model.hud.settingsSection == .models)
    }

    @Test func settingsSectionsHaveTitlesGlyphsAndGroups() {
        #expect(SettingsSection.groups.flatMap { $0 }.count == SettingsSection.allCases.count)
        #expect(SettingsSection.tools.glyph == .folder)
        #expect(SettingsSection.general.title == "General")
    }

    @Test func confirmCopyDependsOnTheProblem() {
        let file = URL(fileURLWithPath: "/tmp/settings.json")
        #expect(
            Strings.SettingsFile.confirm(.newerVersion(file), keptAs: "settings.newer-x.json")
                .hasPrefix("Use default settings? The newer version's file is kept as `settings.newer-x.json`."))
        #expect(
            Strings.SettingsFile.confirm(.unreadable(file), keptAs: "settings.broken-x.json")
                == "Start over with default settings? Your current file is kept as `settings.broken-x.json`.")
        #expect(
            Strings.General.closeOnClickOutsideHelp(shortcut: "⌥ Space")
                == "Off: it stays open until you press Esc or ⌥ Space.")
    }
}

@MainActor
@Suite struct SliceTwoReviewTests {
    private func row(_ action: MenuAction, services: Int = 0, pinned: Int = 0) -> MenuRow? {
        let menu = MenuModel(
            hotkey: .ok(.wakeDefault), focus: .idle(nextLength: 25), caffeine: .off, runningServices: services,
            pinnedChats: pinned, now: now)
        for case .row(let row) in menu.entries where row.action == action { return row }
        return nil
    }

    @Test func anEmptyMenuShowsNoneAndNoCount() {
        #expect(row(.services)?.value == "None")
        #expect(row(.services, services: 1)?.value == "1 running")
        #expect(row(.pinned)?.value == nil)
        #expect(row(.pinned, pinned: 4)?.value == "4")
    }

    @Test func changingTabOrSectionEndsARecording() {
        let model = AppModel.preview()
        model.hud.showSettings(.general)
        model.hud.startRecording()
        model.hud.selectSettingsSection(.general)  // same section: keeps listening
        #expect(model.hud.recording)
        model.hud.selectSettingsSection(.focus)
        #expect(!model.hud.recording)

        model.hud.showSettings(.general)
        model.hud.startRecording()
        model.hud.selectTab(.chat)
        #expect(!model.hud.recording)
    }
}

@MainActor
@Suite struct OpenAtLoginNoteTests {
    private func model(_ item: FakeLoginItem, files: FakeFileRevealer = FakeFileRevealer()) -> AppModel {
        AppModel(
            ports: AppModel.Ports(
                clock: ManualClock(), scheduler: ManualScheduler(clock: ManualClock()),
                hotkeys: FakeHotkeyRegistrar(), appearance: FixedAppearance(), files: files, loginItem: item,
                systemSettings: FakeSystemSettingsLinks(), notifier: FakeNotifier(), dataFolder: nil))
    }

    @Test func anAppOutsideApplicationsAsksToBeMovedAfterTheSwitchFails() {
        let item = FakeLoginItem(
            status: .unavailable, appLocation: URL(fileURLWithPath: "/Users/me/Downloads/HeadsUp.app"))
        let files = FakeFileRevealer()
        let model = model(item, files: files)
        #expect(model.openAtLoginNote == nil)  // not before the user tries
        model.setOpenAtLogin(true)
        #expect(model.openAtLogin == .unavailable)
        #expect(model.openAtLoginNote == .moveToApplications)
        #expect(model.openAtLoginError == nil)
        #expect(Strings.General.loginNote(.moveToApplications).hasPrefix("To open at login, HeadsUp must be in"))
        model.showAppInFinder()
        #expect(files.revealed == [URL(fileURLWithPath: "/Users/me/Downloads/HeadsUp.app")])
    }

    @Test func anAppAlreadyInApplicationsGetsTheOtherNoteWithNoButton() {
        let item = FakeLoginItem(status: .unavailable, appLocation: URL(fileURLWithPath: "/Applications/HeadsUp.app"))
        let model = model(item)
        model.setOpenAtLogin(true)
        #expect(model.openAtLoginNote == .couldNotAdd)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(AppModel.isInApplications(home.appendingPathComponent("Applications/HeadsUp.app")))
        #expect(!AppModel.isInApplications(URL(fileURLWithPath: "/Applications/Utilities/HeadsUp.app")))
    }

    @Test func theNoteGoesAwayWhenTheSwitchTurnsOnSuccessfully() {
        let item = FakeLoginItem(status: .unavailable, appLocation: URL(fileURLWithPath: "/tmp/HeadsUp.app"))
        let model = model(item)
        model.setOpenAtLogin(true)
        #expect(model.openAtLoginNote == .moveToApplications)
        item.status = .disabled  // the user moved it and macOS accepts it now
        model.setOpenAtLogin(true)
        #expect(model.openAtLogin == .enabled)
        #expect(model.openAtLoginNote == nil)
    }

    @Test func approvalNeededShowsItsNote() {
        let model = model(FakeLoginItem(status: .requiresApproval))
        #expect(model.openAtLoginNote == .needsApproval)
        #expect(Strings.General.loginNote(.needsApproval) == Strings.General.loginNeedsApproval)
    }
}

@Suite struct LoginSwitchTests {
    @Test func theSwitchIsOnWhileApprovalIsPending() {
        #expect(LoginItemStatus.enabled.isOn)
        #expect(LoginItemStatus.requiresApproval.isOn)
        #expect(!LoginItemStatus.disabled.isOn)
        #expect(!LoginItemStatus.unavailable.isOn)
    }
}

@MainActor
@Suite struct SliceTwoIntegrationTests {
    @Test func theBodyFollowsItsPrecedence() {
        let model = AppModel.preview(firstLaunch: true)
        #expect(model.body == .welcome)  // first run, on Chat
        model.hud.setInput("focus")
        #expect(model.body == .suggestions)  // typing wins
        model.hud.setInput("")
        model.hud.selectTab(.settings)
        #expect(model.body == .settings)
        model.hud.setInput("theme")
        #expect(model.body == .suggestions)
        model.hud.setInput("")
        model.hud.selectTab(.services)
        #expect(model.body == .empty)
        model.hud.selectTab(.chat)
        #expect(model.body == .empty)  // the welcome is done once another tab was visited
    }

    @Test func resetShowsOnlyForAnotherShortcutWhileNotRecording() {
        let model = AppModel.preview()
        #expect(!model.hud.canResetShortcut)
        model.hud.changeShortcut(Shortcut(keyCode: 40, modifiers: .command, key: "K"))
        #expect(model.hud.canResetShortcut)
        model.hud.startRecording()
        #expect(!model.hud.canResetShortcut)
    }

    @Test func arrowsMoveThroughTheSubNavAndStopAtItsEnds() {
        let model = AppModel.preview()
        model.hud.showSettings(.models)
        model.hud.moveSettingsSection(-1)
        #expect(model.hud.settingsSection == .models)
        var visited: [SettingsSection] = []
        for _ in 0..<7 {
            model.hud.moveSettingsSection(1)
            visited.append(model.hud.settingsSection)
        }
        #expect(visited == [.tools, .focus, .services, .commands, .general, .general, .general])
    }

    @Test func fileNamesAreMarkedForMono() {
        let kept = URL(fileURLWithPath: "/tmp/settings.broken-2026-10-25-120000.json")
        #expect(Strings.SettingsFile.text(.keptAside(kept)).contains("`settings.broken-2026-10-25-120000.json`"))
        #expect(Strings.SettingsFile.text(.defaultsChosen(keptAs: kept)).contains("`settings.broken-"))
    }
}

@MainActor
@Suite struct ArrowRoutingTests {
    @Test func arrowsGoToTheSuggestionsOnlyWhileThereAreAny() {
        let model = AppModel.preview()
        model.hud.showSettings(.general)
        #expect(!model.hud.arrowKeysMoveSelection)  // the sub-nav and controls keep them
        model.hud.setInput("theme")
        #expect(model.hud.arrowKeysMoveSelection)
        model.hud.setInput("")
        #expect(!model.hud.arrowKeysMoveSelection)
    }

    @Test func settingsWinsOverTheWelcomeAndTheWelcomeShowsOnlyOnChat() {
        let onSettings = AppModel.preview(firstLaunch: true)
        onSettings.hud.showSettings(.models)
        #expect(onSettings.body == .settings)
        let onChat = AppModel.preview(firstLaunch: true)
        #expect(onChat.body == .welcome)
        onChat.hud.setInput("x")
        #expect(onChat.body == .suggestions)
    }
}
