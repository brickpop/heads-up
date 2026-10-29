import Foundation
import Testing

@testable import HeadsUpCore

/// A chat with a model, which records what was sent.
@MainActor
private final class FakeChat: HUDChat {
    var askTarget: AskTarget = .model(name: "Llama 3.1 8B")
    var hasMessages = false
    var isBusy = false
    var hasAttachments = false
    var isSendBlocked = false
    var sent: [String] = []
    var stops = 0
    var newChats = 0
    var pinToggles = 0
    func send(_ text: String) { sent.append(text) }
    func stop() { stops += 1 }
    func newChat() { newChats += 1 }
    func togglePin() { pinToggles += 1 }
}

/// A HUDStore with fake ports, a fake window that reports key changes, and settings in memory.
@MainActor
private struct Harness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let window = FakeHUDWindow()
    let hotkeys: FakeHotkeyRegistrar
    let settings: SettingsStore
    let registry = ActionRegistry()
    let chat = FakeChat()
    let hud: HUDStore
    /// Ids of the actions that ran.
    let ran = Ran()

    final class Ran {
        var ids: [String] = []
    }

    init(hotkey: HotkeyStatus? = nil, settings initial: Settings = Settings()) {
        scheduler = ManualScheduler(clock: clock)
        hotkeys = FakeHotkeyRegistrar(nextStatus: hotkey)
        settings = SettingsStore(folder: nil, clock: clock, initial: initial)
        hud = HUDStore(
            clock: clock, scheduler: scheduler, registry: registry, settings: settings, hotkeys: hotkeys, chat: chat)
        window.hud = hud
        hud.attach(window: window)
        let ran = ran
        registry.add(.focus) {
            ["Start 25 min focus", "Start 50 min focus", "Take a break now"].map { title in
                Action(
                    id: ActionID(title), title: title, subtitle: "", kind: .focus, glyph: .timer,
                    keywords: "pomodoro focus", suggest: .oneClick, run: { ran.ids.append(title) })
            }
        }
    }
}

@MainActor
@Suite struct HUDStoreTests {
    // MARK: Esc

    @Test func escapeClosesTheModelMenuThenClearsTheInputThenLeavesPinnedThenCloses() {
        let h = Harness()
        h.hud.open(tab: .chat)
        h.hud.togglePinnedList()
        h.hud.setInput("hello")
        h.hud.toggleModelMenu()
        #expect(h.hud.modelMenuOpen)

        h.hud.escape()
        #expect(!h.hud.modelMenuOpen)
        #expect(h.hud.input == "hello")

        h.hud.escape()
        #expect(h.hud.input == "")
        #expect(h.hud.chatView == .pinned)

        h.hud.escape()
        #expect(h.hud.chatView == .conversation)
        #expect(h.hud.isOpen)

        h.hud.escape()
        #expect(!h.hud.isOpen)
        #expect(!h.window.isVisible)
    }

    @Test func escapeOnAnotherTabWithNothingToClearCloses() {
        let h = Harness()
        h.hud.open(tab: .services)
        h.hud.escape()
        #expect(!h.hud.isOpen)
        #expect(h.hud.tab == .services)
    }

    // MARK: Selection and Enter

    @Test func eachKeystrokeResetsTheSelectionToTheFirstRow() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.moveSelection(1)
        #expect(h.hud.selection == 1)
        h.hud.setInput("focus ")
        #expect(h.hud.selection == 0)
    }

    @Test func arrowsWrapAround() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        #expect(h.hud.suggestions.count == 4)
        h.hud.moveSelection(-1)
        #expect(h.hud.selection == 3)
        h.hud.moveSelection(1)
        #expect(h.hud.selection == 0)
    }

    @Test func hoverSelectsARow() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.hover(2)
        #expect(h.hud.selection == 2)
        h.hud.hover(9)
        #expect(h.hud.selection == 2)
    }

    @Test func enterRunsTheSelectedActionAndClearsTheInput() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.moveSelection(1)
        h.hud.submit()
        #expect(h.ran.ids == ["Start 25 min focus"])
        #expect(h.hud.input == "")
        #expect(h.chat.sent.isEmpty)
    }

    // The prompt field sets its text again, unchanged, as Enter is pressed and before submit.
    @Test func enterAfterTheFieldRecommitsTheSameTextRunsTheSelectedAction() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.moveSelection(1)
        h.hud.setInput("focus")
        #expect(h.hud.selection == 1)
        h.hud.submit()
        #expect(h.ran.ids == ["Start 25 min focus"])
        #expect(h.chat.sent.isEmpty)
    }

    @Test func enterOnTheAskRowSendsToChatFromAnyTab() {
        let h = Harness()
        h.hud.open(tab: .caffeine)
        h.hud.setInput("  what is a pomodoro  ")
        h.hud.submit()
        #expect(h.chat.sent == ["what is a pomodoro"])
        #expect(h.hud.tab == .chat)
        #expect(h.hud.input == "")
    }

    @Test func enterWithNoModelOpensSettingsModelsAndKeepsTheText() {
        let h = Harness()
        h.chat.askTarget = .noModel
        h.hud.open(tab: .focus)
        h.hud.setInput("hello")
        h.hud.submit()
        #expect(h.hud.tab == .settings)
        #expect(h.hud.settingsSection == .models)
        #expect(h.hud.input == "hello")
        #expect(h.chat.sent.isEmpty)
    }

    @Test func aSlashTypoSelectsNothingSoEnterDoesNothing() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("/fcous")
        #expect(h.hud.selection == nil)
        h.hud.submit()
        #expect(h.chat.sent.isEmpty)
        #expect(h.ran.ids.isEmpty)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.noMatch))

        // ↓ then Enter asks.
        h.hud.moveSelection(1)
        #expect(h.hud.selection == 1)
        h.hud.submit()
        #expect(h.chat.sent == ["/fcous"])
    }

    @Test func noMatchCantBeHovered() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("/fcous")
        h.hud.hover(0)
        #expect(h.hud.selection == nil)
    }

    @Test func inAConversationEnterSendsTheReplyWhenNothingMatches() {
        let h = Harness()
        h.chat.hasMessages = true
        h.hud.open(tab: .chat)
        h.hud.setInput("thanks a lot")
        #expect(h.hud.suggestions.isEmpty)
        h.hud.submit()
        #expect(h.chat.sent == ["thanks a lot"])
    }

    @Test func enterOnAnEmptyInputDoesNothing() {
        let h = Harness()
        h.hud.open()
        h.hud.submit()
        #expect(h.chat.sent.isEmpty)
        #expect(h.hud.isOpen)
    }

    // MARK: Tabs and shortcuts

    @Test func commandDigitsSwitchTabs() {
        let h = Harness()
        h.hud.open()
        for (number, keyCode) in KeyCode.digits.enumerated() {
            #expect(h.hud.handleShortcut(Shortcut(keyCode: keyCode, modifiers: .command, key: "\(number + 1)")))
            #expect(h.hud.tab == Tab(number: number + 1))
        }
    }

    @Test func commandCommaOpensSettingsOnTheLastSection() {
        let h = Harness()
        h.hud.open()
        h.hud.selectSettingsSection(.general)
        h.hud.selectTab(.focus)
        #expect(h.hud.handleShortcut(Shortcut(keyCode: KeyCode.comma, modifiers: .command, key: ",")))
        #expect(h.hud.tab == .settings)
        #expect(h.hud.settingsSection == .general)
    }

    @Test func otherKeysAreLeftToTheTextField() {
        let h = Harness()
        h.hud.open()
        #expect(!h.hud.handleShortcut(Shortcut(keyCode: KeyCode.digits[0], modifiers: .option, key: "1")))
        #expect(!h.hud.handleShortcut(Shortcut(keyCode: KeyCode.digits[0], modifiers: [.command, .shift], key: "1")))
        #expect(h.hud.tab == .chat)
    }

    @Test func selectingATabOpensAClosedHUDAndClosesTheModelMenu() {
        let h = Harness()
        h.hud.toggleModelMenu()
        h.hud.selectTab(.services)
        #expect(h.hud.isOpen)
        #expect(h.hud.isKey)
        #expect(h.hud.tab == .services)
        #expect(!h.hud.modelMenuOpen)
    }

    @Test func leavingChatResetsThePinnedList() {
        let h = Harness()
        h.hud.open()
        h.hud.togglePinnedList()
        h.hud.selectTab(.focus)
        h.hud.selectTab(.chat)
        #expect(h.hud.chatView == .conversation)
    }

    @Test func closingClearsTheInputAndReopeningKeepsTheTab() {
        let h = Harness()
        h.hud.open(tab: .commands)
        h.hud.setInput("ssh")
        h.hud.close()
        #expect(h.hud.input == "")
        h.hud.open()
        #expect(h.hud.tab == .commands)
    }

    // MARK: Placeholder and footer

    @Test func placeholderFollowsTheTabAndTheChat() {
        let h = Harness()
        h.hud.open(tab: .chat)
        #expect(h.hud.placeholder == "Ask anything, or type /")
        h.chat.hasMessages = true
        #expect(h.hud.placeholder == "Reply…")
        h.chat.askTarget = .noModel
        #expect(h.hud.placeholder == "Add a model to chat, or type /")
        h.hud.selectTab(.focus)
        #expect(h.hud.placeholder == "Search actions or ask…")
    }

    @Test func footerHintsFollowTheContext() {
        let h = Harness()
        h.hud.open(tab: .chat)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.chat))
        h.hud.selectTab(.focus)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.otherTabEmpty))  // ⌘←→ tabs, with the prompt empty
        h.hud.setInput("focus")
        #expect(h.hud.footerLeft == .hints(Strings.Hints.suggestions))
    }

    @Test func aToastReplacesTheHintsForTwoPointSixSeconds() {
        let h = Harness()
        h.hud.open(tab: .focus)
        h.hud.toast("Focus started · 25 min")
        #expect(h.hud.footerLeft == .toast("Focus started · 25 min"))
        h.scheduler.advance(by: 2.5)
        #expect(h.hud.footerLeft == .toast("Focus started · 25 min"))
        h.scheduler.advance(by: 0.1)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.otherTabEmpty))
    }

    @Test func aNewToastReplacesTheCurrentOneAndRestartsTheTimer() {
        let h = Harness()
        h.hud.toast("Caffeine off")
        h.scheduler.advance(by: 2)
        h.hud.toast("Model: Llama 3.1 8B")
        h.scheduler.advance(by: 2)
        #expect(h.hud.footerLeft == .toast("Model: Llama 3.1 8B"))
        h.scheduler.advance(by: 0.6)
        #expect(h.hud.footerLeft == .hints(Strings.Hints.chat))
        #expect(h.scheduler.pendingCount == 0)
    }

    // MARK: Click outside

    @Test func aClickElsewhereClosesTheHUD() {
        let h = Harness()
        h.hud.open()
        #expect(h.hud.isKey)
        #expect(h.hud.keySince == h.clock.now)
        h.window.clickElsewhere()
        #expect(!h.hud.isOpen)
    }

    @Test func aClickElsewhereKeepsItOpenWhenTheSettingIsOff() {
        var settings = Settings()
        settings.general.closeOnClickOutside = false
        let h = Harness(settings: settings)
        h.hud.open()
        h.window.clickElsewhere()
        #expect(h.hud.isOpen)
        #expect(!h.hud.isKey)
    }

    @Test func aClickElsewhereKeepsItOpenWhileOurPanelOrAlertShows() {
        let h = Harness()
        h.hud.open()
        h.hud.beginModal()
        h.window.clickElsewhere()
        #expect(h.hud.isOpen)
        h.hud.endModal()
        #expect(h.hud.modalDepth == 0)
    }

    @Test func anAutoOpenedHUDIsNotKeyAndStaysOpen() {
        let h = Harness()
        h.hud.open(tab: .focus, makeKey: false)
        #expect(h.hud.isOpen)
        #expect(!h.hud.isKey)
        h.window.clickElsewhere()
        #expect(h.hud.isOpen)
    }

    // MARK: Wake shortcut

    @Test func theShortcutOpensAndClosesTheHUD() {
        let h = Harness()
        h.hud.registerHotkey()
        #expect(h.hud.hotkey == .ok(.wakeDefault))
        h.hotkeys.press()
        #expect(h.hud.isOpen && h.hud.isKey)
        h.hotkeys.press()
        #expect(!h.hud.isOpen)
    }

    @Test func theShortcutMakesAnAutoOpenedHUDKeyInsteadOfClosingIt() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.open(tab: .focus, makeKey: false)
        h.hotkeys.press()
        #expect(h.hud.isOpen)
        #expect(h.hud.isKey)
        // Now it has been key: the next press closes it.
        h.hotkeys.press()
        #expect(!h.hud.isOpen)
    }

    @Test func theShortcutClosesAnOpenHUDThatLostFocus() {
        var settings = Settings()
        settings.general.closeOnClickOutside = false
        let h = Harness(settings: settings)
        h.hud.registerHotkey()
        h.hotkeys.press()
        h.window.clickElsewhere()
        #expect(h.hud.isOpen && !h.hud.isKey)
        h.hotkeys.press()
        #expect(!h.hud.isOpen)
    }

    @Test func anAutoOpenedHUDThatWasKeyAndLostFocusClosesOnTheShortcut() {
        var settings = Settings()
        settings.general.closeOnClickOutside = false
        let h = Harness(settings: settings)
        h.hud.registerHotkey()
        h.hud.open(tab: .focus, makeKey: false)
        h.hud.open(makeKey: true)  // the user clicked it
        h.window.clickElsewhere()
        h.hotkeys.press()
        #expect(!h.hud.isOpen)
    }

    @Test func aTakenShortcutIsReportedAndCanBeRetried() {
        let h = Harness(hotkey: .taken)
        h.hud.registerHotkey()
        #expect(h.hud.hotkey == .taken)
        #expect(
            Strings.Hotkey.problem(h.hud.hotkey, shortcut: .wakeDefault)
                == "⌥ Space is used by another app. Choose another.")
        h.hotkeys.nextStatus = nil
        h.hud.retryHotkey()
        #expect(h.hud.hotkey == .ok(.wakeDefault))
    }

    @Test func registrationUsesTheShortcutFromSettings() {
        var settings = Settings()
        let commandK = Shortcut(keyCode: 40, modifiers: .command, key: "K")
        settings.general.shortcut = commandK
        let h = Harness(settings: settings)
        h.hud.registerHotkey()
        #expect(h.hotkeys.registered == commandK)
        #expect(h.hud.hotkey == .ok(commandK))
    }

    @Test func aNewShortcutIsSavedOnlyWhenItRegisters() {
        let h = Harness()
        h.hud.registerHotkey()
        let commandK = Shortcut(keyCode: 40, modifiers: .command, key: "K")
        let controlSpace = Shortcut(keyCode: KeyCode.space, modifiers: .control, key: "Space")

        #expect(h.hud.changeShortcut(commandK) == .ok(commandK))
        #expect(h.settings.settings.general.shortcut == commandK)

        h.hotkeys.nextStatus = .taken
        #expect(h.hud.changeShortcut(controlSpace) == .taken)
        // The previous shortcut stays registered, saved and working.
        #expect(h.hud.hotkey == .ok(commandK))
        #expect(h.settings.settings.general.shortcut == commandK)
        #expect(h.hotkeys.registered == commandK)
        h.hotkeys.press()
        #expect(h.hud.isOpen)
    }
}

@MainActor
@Suite struct ShortcutRecorderTests {
    private let commandK = Shortcut(keyCode: 40, modifiers: .command, key: "K")

    @Test func recordingReleasesTheShortcutUntilItEnds() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.open()
        h.hud.startRecording()
        #expect(h.hud.recording)
        h.hotkeys.press()  // the recorder captures ⌥ Space instead
        #expect(h.hud.isOpen)
        h.hud.cancelRecording()
        h.hotkeys.press()
        #expect(!h.hud.isOpen)
    }

    @Test func aNewShortcutIsSavedAndEndsRecording() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.startRecording()
        h.hud.record(commandK)
        #expect(!h.hud.recording)
        #expect(h.hud.recorderProblem == nil)
        #expect(h.settings.settings.general.shortcut == commandK)
        #expect(h.hud.hotkey == .ok(commandK))
        #expect(!h.hotkeys.isSuspended)
    }

    @Test func aPlainLetterAsksForAModifierAndKeepsListening() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.startRecording()
        h.hud.record(Shortcut(keyCode: 40, modifiers: .shift, key: "K"))
        #expect(h.hud.recording)
        #expect(h.hud.recorderProblem == "Add ⌘, ⌥ or ⌃.")
        #expect(h.settings.settings.general.shortcut == .wakeDefault)
    }

    @Test func escCancelsAndKeepsTheCurrentShortcut() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.startRecording()
        h.hud.record(Shortcut(keyCode: KeyNames.escape, modifiers: [], key: "⎋"))
        #expect(!h.hud.recording)
        #expect(h.settings.settings.general.shortcut == .wakeDefault)
        #expect(!h.hotkeys.isSuspended)
    }

    @Test func aTakenShortcutSaysSoAndTheOldOneStays() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.startRecording()
        h.hotkeys.nextStatus = .taken
        h.hud.record(commandK)
        #expect(h.hud.recording)
        #expect(h.hud.recorderProblem == "Another app already uses this shortcut. Choose another.")
        #expect(h.settings.settings.general.shortcut == .wakeDefault)
        #expect(h.hud.hotkey == .ok(.wakeDefault))
        #expect(h.hotkeys.isSuspended)  // still listening

        h.hotkeys.nextStatus = .reservedBySystem
        h.hud.record(Shortcut(keyCode: KeyCode.space, modifiers: .command, key: "Space"))
        #expect(h.hud.recorderProblem?.hasPrefix("⌘ Space is used by macOS.") == true)
    }

    @Test func threeReRecordingsLeaveOnlyTheLastOneWorking() {
        let h = Harness()
        h.hud.registerHotkey()
        for shortcut in [
            commandK, Shortcut(keyCode: 46, modifiers: .command, key: "M"),
            Shortcut(keyCode: KeyCode.space, modifiers: .control, key: "Space"),
        ] {
            h.hud.startRecording()
            h.hud.record(shortcut)
        }
        #expect(h.hotkeys.registered == Shortcut(keyCode: KeyCode.space, modifiers: .control, key: "Space"))
        #expect(h.settings.settings.general.shortcut.modifiers == .control)
    }

    @Test func resetGoesBackToOptionSpace() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.changeShortcut(commandK)
        h.hud.resetShortcut()
        #expect(h.settings.settings.general.shortcut == .wakeDefault)
        #expect(h.hud.recorderProblem == nil)
    }
}

@MainActor
@Suite struct RowPresentationTests {
    @Test func runningARowSelectsAndRunsIt() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.run(rowAt: 2)
        #expect(h.ran.ids == ["Start 50 min focus"])
        #expect(h.hud.input == "")
    }

    @Test func noMatchCantBeRun() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("/fcous")
        h.hud.run(rowAt: 0)
        #expect(h.chat.sent.isEmpty)
        #expect(h.hud.input == "/fcous")
        h.hud.run(rowAt: 9)  // out of range
        #expect(h.chat.sent.isEmpty)
    }

    @Test func rowsShowTitleSubtitleKindAndGlyph() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        let ask = h.hud.suggestions[0]
        #expect(ask.title == "Ask Llama 3.1 8B")
        #expect(ask.subtitle == "“focus”")
        #expect(ask.kindLabel == "Chat")
        #expect(ask.glyph == .sparkle)
        let action = h.hud.suggestions[1]
        #expect(action.kindLabel == "Focus")
        #expect(action.glyph == .timer)
    }

    @Test func voiceOverCountsOnlySelectableRows() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        #expect(h.hud.accessibilityLabel(forRow: 1) == "Start 25 min focus, Focus, 2 of 4")
        h.hud.setInput("/fcous")
        #expect(h.hud.accessibilityLabel(forRow: 0) == "No matching actions")
        #expect(h.hud.accessibilityLabel(forRow: 1) == "Ask Llama 3.1 8B, Chat, 1 of 1")
    }

    @Test func theSelectionKnowsWhatMovedIt() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        #expect(h.hud.selectionChange == .typing)
        h.hud.moveSelection(1)
        #expect(h.hud.selectionChange == .keyboard)
        h.hud.hover(3)
        #expect(h.hud.selectionChange == .pointer)
        h.hud.setInput("focu")
        #expect(h.hud.selectionChange == .typing)
        h.hud.setInput("/fcous")
        h.hud.moveSelection(1)  // from nothing selected
        #expect(h.hud.selectionChange == .keyboard)
    }

    @Test func hoveringTheSelectedRowAgainChangesNothing() {
        let h = Harness()
        h.hud.open()
        h.hud.setInput("focus")
        h.hud.moveSelection(1)
        h.hud.hover(1)
        #expect(h.hud.selectionChange == .keyboard)
    }

    @Test func twoIdenticalToastsAreTwoToasts() {
        let h = Harness()
        h.hud.toast("Caffeine off")
        let first = h.hud.toastID
        h.hud.toast("Caffeine off")
        #expect(h.hud.toastID == first + 1)
        #expect(h.hud.footerLeft == .toast("Caffeine off"))
    }
}

@MainActor
@Suite struct RecordingEndsTests {
    @Test func closingTheHUDEndsARecordingAndTheShortcutWorksAgain() {
        let h = Harness()
        h.hud.registerHotkey()
        h.hud.open()
        h.hud.startRecording()
        #expect(h.hotkeys.isSuspended)
        h.hud.close()
        #expect(!h.hud.recording)
        #expect(!h.hotkeys.isSuspended)
        h.hotkeys.press()
        #expect(h.hud.isOpen)
    }

    @Test func losingTheKeyboardEndsARecordingEvenWhenTheHUDStaysOpen() {
        var settings = Settings()
        settings.general.closeOnClickOutside = false
        let h = Harness(settings: settings)
        h.hud.registerHotkey()
        h.hud.open()
        h.hud.startRecording()
        h.window.clickElsewhere()
        #expect(h.hud.isOpen)
        #expect(!h.hud.recording)
        #expect(!h.hotkeys.isSuspended)
    }
}
