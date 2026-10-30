import Foundation
import Testing

@testable import HeadsUpCore

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// An AppModel with a fake terminal launcher, a real data folder, and fake everything else.
@MainActor
private final class CommandsHarness {
    let clock = ManualClock()
    let terminals: FakeTerminalLauncher
    let picker = FakeOpenPanels()
    let revealer = FakeFileRevealer()
    let systemSettings = FakeSystemSettingsLinks()
    let folder: URL
    let work: URL
    let home: String
    private let ownsRoot: Bool
    private(set) var model: AppModel!
    var commands: CommandStore { model.commands }

    init(
        installed: [Terminal] = [.terminal], file: String? = nil, sharing other: CommandsHarness? = nil,
        loginShell: String = "/bin/zsh"
    ) throws {
        terminals = FakeTerminalLauncher(terminals: installed)
        let root =
            other?.folder.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("headsup-cmds-\(UUID().uuidString)")
        ownsRoot = other == nil
        home = root.path
        folder = root.appendingPathComponent("HeadsUp")
        work = root.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        if let file {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(file.utf8).write(to: folder.appendingPathComponent("commands.json"))
        }
        var settings = Settings()
        settings.general.welcomeDone = true
        model = AppModel(
            ports: AppModel.Ports(
                clock: clock, scheduler: ManualScheduler(clock: clock), hotkeys: FakeHotkeyRegistrar(),
                appearance: FixedAppearance(), files: revealer, loginItem: FakeLoginItem(),
                systemSettings: systemSettings, notifier: FakeNotifier(), powerAssertions: FakePowerAssertions(),
                powerSource: FakePowerSource(), serviceLauncher: FakeServiceLauncher(), portProbe: FakePortProbe(),
                openPanels: picker, imageProcessor: FakeImageProcessor(), calendar: FakeCalendarReader(),
                reminders: FakeRemindersAccess(), terminalLauncher: terminals,
                secrets: MemorySecretStore(),
                httpClient: FakeHTTPClient(), linkOpener: FakeLinkOpener(), pasteboard: FakePasteboard(),
                dataFolder: folder, loginShell: loginShell,
                home: home, environment: ["PATH": "/usr/bin"]),
            settings: settings)
        model.launch()
    }

    deinit {
        guard ownsRoot else { return }
        chmod(folder.path, 0o700)
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    @discardableResult
    func add(_ name: String = "SSH into staging", command: String = "ssh deploy@staging") -> CommandDefinition.ID {
        let definition = CommandDefinition(name: name, command: command, cwd: work.path)
        #expect(commands.save(definition).isEmpty)
        return definition.id
    }

    var file: URL { folder.appendingPathComponent("commands.json") }
    var toast: FooterLeft { model.hud.footerLeft }

    func makeFolderReadOnly() {
        #expect(mkdir(folder.path, 0o700) == 0 || errno == EEXIST)
        #expect(chmod(folder.path, 0o500) == 0)
    }
}

@MainActor
@Suite(.serialized) struct CommandStoreTests {
    // MARK: commands.json

    @Test func aFreshInstallCreatesNoFileUntilACommandIsSaved() throws {
        let h = try CommandsHarness()
        #expect(h.commands.definitions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.file.path))
        h.add()
        #expect(h.toast == .toast("Added SSH into staging"))
        let mode = try FileManager.default.attributesOfItem(atPath: h.file.path)[.posixPermissions] as! NSNumber
        #expect(mode.intValue & 0o777 == 0o600)
        let next = try CommandsHarness(sharing: h)
        #expect(next.commands.definitions.map(\.name) == ["SSH into staging"])
    }

    @Test func aFileMissingTheFolderLoadsWithHome() throws {
        let h = try CommandsHarness(file: #"{ "commands": [ { "name": "htop", "command": "htop" } ] }"#)
        #expect(h.commands.definitions.first?.cwd == "~" && h.commands.canEdit)
    }

    @Test func aBrokenFileIsNeverOverwrittenAndTheCardSaysWhy() throws {
        let broken = #"{ "commands": [ { "command": "htop" } ] }"#
        let h = try CommandsHarness(file: broken)
        #expect(h.commands.loadError == .unreadable(reason: "command 1 has no name"))
        let card = try #require(h.commands.screen.fileProblem)
        #expect(card.title == "Your commands couldn't be loaded")
        #expect(
            card.text
                == "HeadsUp couldn't read `commands.json` (command 1 has no name), so it left the file as it is. Fix it, then try again."
        )
        #expect(h.commands.screen.empty == nil && !h.commands.settingsScreen.addEnabled)
        #expect(
            h.commands.save(CommandDefinition(name: "x", command: "y"))
                == [.file: "You can't change commands until `commands.json` can be read."])
        #expect(String(decoding: try Data(contentsOf: h.file), as: UTF8.self) == broken)
        h.commands.revealCommandsFile()
        #expect(h.revealer.revealed == [h.file])
        try Data(#"{ "commands": [ { "name": "htop", "command": "htop" } ] }"#.utf8).write(to: h.file)
        h.commands.reloadCommands()
        #expect(h.commands.loadError == nil && h.commands.definitions.count == 1)
    }

    @Test func aFileFromANewerVersionIsLeftAlone() throws {
        let h = try CommandsHarness(file: #"{ "version": 2, "commands": [] }"#)
        #expect(h.commands.loadError == .newerVersion)
        #expect(h.commands.screen.fileProblem?.tryAgain == nil)
    }

    @Test func aSaveThatCantBeWrittenKeepsTheListOnDisk() throws {
        let h = try CommandsHarness()
        h.add()
        h.makeFolderReadOnly()
        let problems = h.commands.save(CommandDefinition(name: "htop", command: "htop", cwd: h.work.path))
        #expect(problems == [.file: "Couldn't save: HeadsUp isn't allowed to write to its settings folder."])
        #expect(h.toast != .toast("Added htop"))
        #expect(h.commands.definitions.count == 1)
        #expect(try CommandsHarness(sharing: h).commands.definitions.count == 1)
        #expect(h.commands.delete(h.commands.definitions[0].id)[.file] != nil)
        #expect(h.commands.definitions.count == 1)
    }

    // Scan L2, as for services: a hand-edited command that breaks a rule can't run.
    @Test func aCommandThatBreaksARuleCantRunAndSaysWhy() async throws {
        let h = try CommandsHarness(
            file: #"{ "commands": [ { "id": "a", "name": "Bad", "command": "ls\u0000rm" } ] }"#)
        let row = try #require(h.commands.screen.rows.first)
        #expect(row.meta == "Can't run · this has a hidden character that can't be used. Type it again")
        #expect(row.action == .edit(title: "Edit…") && row.problem == nil)
        #expect(!h.model.registry.actions.contains { $0.id == ActionID("command.run:a") })
        await h.model.runCommand("a").value
        #expect(h.terminals.ran.isEmpty)
    }

    // MARK: Terminals

    @Test func onlyInstalledTerminalsThatCanRunACommandAreOffered() throws {
        let h = try CommandsHarness(installed: [.terminal, .iterm2, .warp])
        let picker = try #require(h.commands.screen.terminalPicker)
        #expect(picker.label == "Opens in")
        #expect(picker.choices.map(\.title) == ["Terminal", "iTerm2"])
        #expect(picker.choices.map(\.isSelected) == [true, false])
        #expect(picker.selectedID == "com.apple.Terminal" && picker.style == .segmented)
        #expect(h.commands.terminalSetting?.label == "Terminal app")
    }

    @Test func thePickerIsHiddenWithOneTerminal() throws {
        let h = try CommandsHarness(installed: [.terminal, .warp])
        #expect(h.commands.screen.terminalPicker == nil && h.commands.terminalSetting == nil)
    }

    @Test func choosingATerminalIsSavedInSettings() throws {
        let h = try CommandsHarness(installed: [.terminal, .iterm2, .warp])
        h.commands.setTerminal("com.googlecode.iterm2")
        #expect(h.model.settings.settings.general.terminalBundleID == "com.googlecode.iterm2")
        #expect(h.commands.terminal?.terminal == .iterm2)
        h.commands.setTerminal(Terminal.warp.bundleID)
        h.commands.setTerminal("com.example.nope")
        #expect(h.model.settings.settings.general.terminalBundleID == "com.googlecode.iterm2")
    }

    @Test func aChosenTerminalThatWasRemovedFallsBackToTheFirst() throws {
        let h = try CommandsHarness(installed: [.terminal, .kitty])
        h.commands.setTerminal(Terminal.kitty.bundleID)
        h.terminals.terminals = [.terminal]
        h.model.hud.selectTab(.commands)  // terminals are looked for again
        #expect(h.commands.terminal?.terminal == .terminal)
    }

    // MARK: Running

    @Test func runningOpensTheTerminalWithTheCommandAsData() async throws {
        let h = try CommandsHarness()
        let id = h.add(command: #"echo "a\b" $HOME; ls"#)
        h.model.hud.selectTab(.commands)
        let toasts = h.model.hud.toastID
        await h.model.runCommand(id).value
        // One leading space keeps it out of history in shells set to ignore such lines.
        #expect(h.terminals.ran == [.script(.terminal, directory: h.work.path, command: #" echo "a\b" $HOME; ls"#)])
        // No toast: the HUD closes at once, so nothing would show it.
        #expect(h.model.hud.toastID == toasts)
    }

    @Test func kittyRunsThroughOpenWithAnArgv() async throws {
        let h = try CommandsHarness(installed: [.terminal, .kitty])
        h.commands.setTerminal(Terminal.kitty.bundleID)
        let id = h.add()
        await h.model.runCommand(id).value
        guard case .process(let executable, let arguments) = h.terminals.ran.first else {
            Issue.record("expected a process")
            return
        }
        #expect(executable == "/usr/bin/open")
        #expect(
            Array(arguments.prefix(4)) == ["-na", "/Applications/Kitty.app", "--args", "--directory=\(h.work.path)"])
    }

    // App shell, "After launching a command": the terminal is what the user wants to see.
    @Test func theHUDClosesOnceTheCommandOpenedEvenWhileItIsKey() async throws {
        let h = try CommandsHarness()
        let id = h.add()
        h.model.hud.selectTab(.commands)
        h.model.hud.didBecomeKey()
        h.model.hud.setInput("ssh")
        let running = h.model.runCommand(id)
        h.model.hud.didResignKey()  // the terminal comes forward while the command opens
        #expect(h.model.hud.isOpen)  // held open while the terminal opens
        await running.value
        #expect(!h.model.hud.isOpen)
        #expect(h.model.hud.input == "")
    }

    @Test func aFailedLaunchKeepsTheHUDOpenWithTheProblem() async throws {
        let h = try CommandsHarness()
        let id = h.add()
        h.terminals.result = .failed("no such app")
        h.model.hud.selectTab(.commands)
        h.model.hud.didBecomeKey()
        await h.model.runCommand(id).value
        #expect(h.model.hud.isOpen && h.model.hud.tab == .commands)
        #expect(h.commands.screen.rows.first?.problem?.text == "Couldn't open Terminal (no such app).")
    }

    @Test func aRefusalShowsUnderTheRowWithTheFixAndKeepsTheHUDOpen() async throws {
        let h = try CommandsHarness(installed: [.terminal, .iterm2])
        h.commands.setTerminal("com.googlecode.iterm2")
        let id = h.add()
        h.terminals.result = .notAllowed
        h.model.hud.selectTab(.chat)
        h.model.hud.didBecomeKey()
        let toasts = h.model.hud.toastID
        let running = h.model.runCommand(id)
        h.model.hud.didResignKey()  // the Automation prompt takes the keyboard
        await running.value
        #expect(h.model.hud.isOpen && h.model.hud.tab == .commands)
        #expect(h.model.hud.toastID == toasts)
        let problem = try #require(h.commands.screen.rows.first?.problem)
        #expect(problem.text == "macOS didn't let HeadsUp open iTerm2. Allow it in Privacy & Security → Automation.")
        #expect(problem.fix == CommandsScreen.Fix(kind: .openAutomation, title: "Open System Settings"))
        h.model.openAutomationSettings()
        #expect(h.systemSettings.opened == ["automation"])

        // The next attempt starts clean; so does another terminal.
        h.terminals.result = .opened
        await h.model.runCommand(id).value
        #expect(h.commands.screen.rows.first?.problem == nil)
        h.terminals.result = .failed("no such app")
        await h.model.runCommand(id).value
        #expect(h.commands.screen.rows.first?.problem?.text == "Couldn't open iTerm2 (no such app).")
        #expect(h.commands.screen.rows.first?.problem?.fix.kind == .tryAgain)
        h.commands.setTerminal("com.apple.Terminal")
        #expect(h.commands.screen.rows.first?.problem == nil)
    }

    @Test func theRunActionCanNeverBeSuggested() throws {
        let h = try CommandsHarness()
        let id = h.add()
        let action = try #require(h.model.registry.actions.first { $0.id == ActionID("command.run:\(id)") })
        #expect(action.title == "Run SSH into staging" && action.kind == .command && action.suggest == .never)
    }

    @Test func theCommandsTabHasItsOwnBodyAndEmptyState() throws {
        let h = try CommandsHarness()
        h.model.hud.selectTab(.commands)
        #expect(h.model.body == .commands)
        let empty = try #require(h.commands.screen.empty)
        #expect(empty.title == "No commands yet" && empty.add == "Add a command…")
        #expect(h.commands.screen.label == "Command shortcuts")
    }
}

@MainActor
@Suite(.serialized) struct CommandFormTests {
    @Test func addingEditingAndRemovingACommand() throws {
        let h = try CommandsHarness()
        h.model.addCommand()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .commands)
        var form = try #require(h.commands.settingsScreen.form)
        #expect(form.title == "New command" && form.cwd == "~" && form.remove == nil)
        h.commands.updateDraft {
            $0.name = "Rebase"
            $0.command = "git rebase -i HEAD~3"
            $0.cwd = h.work.path
        }
        h.commands.saveForm()
        #expect(h.commands.form == nil && h.toast == .toast("Added Rebase"))
        let id = try #require(h.commands.definitions.first?.id)
        #expect(h.commands.settingsScreen.rows.map(\.name) == ["Rebase"])

        h.commands.editCommand(id)
        form = try #require(h.commands.settingsScreen.form)
        #expect(form.title == "Rebase" && form.remove == "Remove…")
        h.commands.askRemove()
        #expect(
            h.commands.settingsScreen.form?.bar
                == .remove(question: "Remove Rebase?", cancel: "Cancel", remove: "Remove"))
        h.commands.confirmRemove()
        #expect(h.commands.form == nil && h.commands.definitions.isEmpty && h.toast == .toast("Removed Rebase"))
    }

    @Test func theFormsProblemsAndAFailedSave() throws {
        let h = try CommandsHarness()
        h.commands.editCommand(nil)
        h.commands.updateDraft { $0.cwd = "/no/such/folder" }
        h.commands.saveForm()
        let problems = try #require(h.commands.settingsScreen.form?.problems)
        #expect(problems[.name] == "Enter a name." && problems[.command] == "Enter a command to run.")
        #expect(problems[.cwd] == "This folder doesn't exist.")
        h.commands.updateDraft {
            $0.name = "htop"
            $0.command = "htop"
            $0.cwd = h.work.path
        }
        #expect(h.commands.form?.problems.isEmpty == true)
        h.makeFolderReadOnly()
        h.commands.saveForm()
        #expect(h.commands.settingsScreen.form?.saveProblem?.hasPrefix("Couldn't save: ") == true)
        #expect(h.commands.definitions.isEmpty)
    }

    @Test func escCancelsTheCommandForm() throws {
        let h = try CommandsHarness()
        h.model.addCommand()
        h.commands.updateDraft { $0.name = "W" }
        h.model.escape()
        #expect(
            h.commands.settingsScreen.form?.bar
                == .discard(question: "Discard your changes?", keep: "Keep editing", discard: "Discard"))
        h.model.escape()
        #expect(h.commands.form?.bar == CommandForm.Bar.none && h.model.hud.isOpen)
        h.commands.cancelForm()
        h.commands.discardForm()
        #expect(h.commands.form == nil)
        h.model.addCommand()
        h.model.escape()  // no changes: the form just closes
        #expect(h.commands.form == nil)
    }

    @Test func chooseFolderWritesItIntoTheDraft() async throws {
        let h = try CommandsHarness()
        h.model.addCommand()
        h.picker.answer = h.home + "/code"
        await h.model.chooseCommandFolder().value
        #expect(h.picker.openedAt == [h.home])
        #expect(h.commands.form?.draft.cwd == "~/code")
    }

    @Test func aCommandThatBreaksARuleOpensWithItsProblem() throws {
        let h = try CommandsHarness(file: #"{ "commands": [ { "id": "a", "name": "Bad", "command": " " } ] }"#)
        h.commands.editCommand("a")
        #expect(h.commands.settingsScreen.form?.problems[.command] == "Enter a command to run.")
    }
}

/// The slice 6 fix loop: Yuki's copy and fixes, the row's action and VoiceOver, the picker.
@MainActor
@Suite(.serialized) struct CommandsScreenRoundTwoTests {
    @Test func eachRunProblemHasItsFix() async throws {
        let h = try CommandsHarness()
        let id = h.add()
        h.terminals.result = .notInstalled
        await h.model.runCommand(id).value
        var problem = try #require(h.commands.screen.rows.first?.problem)
        #expect(problem.text == "Terminal isn't on this Mac any more. Choose another terminal in Settings → General.")
        #expect(problem.fix == CommandsScreen.Fix(kind: .openGeneral, title: "Open Settings"))
        h.model.openTerminalSetting()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .general)
        h.terminals.result = .failed("")
        await h.model.runCommand(id).value
        problem = try #require(h.commands.screen.rows.first?.problem)
        #expect(problem.text == "Couldn't open Terminal.")
        #expect(problem.fix == CommandsScreen.Fix(kind: .tryAgain, title: "Try Again"))
    }

    @Test func theRowReadsWellToVoiceOver() throws {
        let h = try CommandsHarness(installed: [.terminal, .iterm2])
        h.commands.setTerminal("com.googlecode.iterm2")
        #expect(
            h.commands.save(CommandDefinition(id: "a", name: "SSH into staging", command: "ssh deploy@staging")).isEmpty
        )
        let row = try #require(h.commands.screen.rows.first)
        #expect(row.accessibilityLabel == "SSH into staging")
        #expect(row.accessibilityValue == "ssh deploy@staging, in home folder")
        #expect(row.accessibilityHint == "Opens in iTerm2")
        #expect(row.action == .run && row.meta == nil)
        #expect(
            Strings.Commands.accessibilityValue(command: "git rebase -i", cwd: "~/code/web-app")
                == "git rebase -i, in home folder/code/web-app")
    }

    @Test func aBrokenCommandOpensItsFormAndNeverRuns() async throws {
        let h = try CommandsHarness(file: #"{ "commands": [ { "id": "a", "name": "Bad", "command": " " } ] }"#)
        #expect(h.commands.screen.rows.first?.action == .edit(title: "Edit…"))
        #expect(h.commands.screen.rows.first?.meta == "Can't run · enter a command to run")
        h.model.editCommand("a")
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .commands)
        #expect(h.commands.settingsScreen.form?.problems[.command] == "Enter a command to run.")
        await h.model.runCommand("a").value
        #expect(h.terminals.ran.isEmpty)
    }

    @Test func moreThanThreeTerminalsUseAMenu() throws {
        let h = try CommandsHarness(installed: [.terminal, .iterm2, .ghostty, .kitty])
        let picker = try #require(h.commands.terminalSetting)
        #expect(picker.style == .menu && picker.label == "Terminal app" && picker.choices.count == 4)
    }

    @Test func theHeadersEditOpensCommandsSettings() throws {
        let h = try CommandsHarness()
        #expect(h.commands.screen.edit == "Edit…")
        h.model.openCommandsSettings()
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .commands)
    }

    @Test func theSettingsIntroIsYukis() throws {
        #expect(
            try CommandsHarness().commands.settingsScreen.intro
                == "Commands you type often. HeadsUp opens each one in your terminal, in its folder.")
    }
}

/// ↑ ↓ pick a command and ⌘↩ runs it, with the prompt empty on Commands (CEO, 2026-10-29).
@MainActor
@Suite(.serialized) struct CommandsKeysTests {
    private let commandReturn = Shortcut(keyCode: KeyCode.returnKey, modifiers: .command, key: "↩")

    private func selected(_ h: CommandsHarness) -> [String] {
        h.commands.screen.rows.filter(\.isSelected).map(\.name)
    }

    /// The run is a task the key doesn't hand back: wait for the fake terminal to see it.
    private func waitForRun(_ h: CommandsHarness, count: Int = 1) async {
        for _ in 0..<100 where h.terminals.ran.count < count { await Task.yield() }
    }

    @Test func theFirstRowIsSelectedAndArrowsStopAtTheEnds() throws {
        let h = try CommandsHarness()
        h.add("One", command: "echo 1")
        h.add("Two", command: "echo 2")
        h.add("Three", command: "echo 3")
        h.model.hud.selectTab(.commands)
        #expect(selected(h) == ["One"])
        #expect(h.model.moveCommandSelection(by: -1))  // at the start: handled, no move
        #expect(h.commands.keyboardMoves == 0)
        #expect(h.model.moveCommandSelection(by: 1) && h.model.moveCommandSelection(by: 1))
        #expect(selected(h) == ["Three"])
        #expect(h.commands.keyboardMoves == 2)
        #expect(h.model.moveCommandSelection(by: 1))
        #expect(selected(h) == ["Three"] && h.commands.keyboardMoves == 2)
        #expect(h.model.moveCommandSelection(by: -1))
        #expect(selected(h) == ["Two"])
    }

    @Test func downDownThenCommandReturnRunsTheThirdAndClosesTheHUD() async throws {
        let h = try CommandsHarness()
        h.add("One", command: "echo 1")
        h.add("Two", command: "echo 2")
        h.add("Three", command: "echo 3")
        h.model.hud.selectTab(.commands)
        _ = h.model.moveCommandSelection(by: 1)
        _ = h.model.moveCommandSelection(by: 1)
        #expect(h.model.handleShortcut(commandReturn))
        await waitForRun(h)
        #expect(h.terminals.ran == [.script(.terminal, directory: h.work.path, command: " echo 3")])
        for _ in 0..<100 where h.model.hud.isOpen { await Task.yield() }
        #expect(!h.model.hud.isOpen)  // as a click: the terminal opens, the HUD closes
    }

    @Test func textAnotherTabOrNoCommandsLeaveTheKeysToThePrompt() throws {
        let h = try CommandsHarness()
        h.model.hud.selectTab(.commands)
        #expect(!h.model.moveCommandSelection(by: 1))  // no commands
        #expect(!h.model.handleShortcut(commandReturn))
        h.add("One", command: "echo 1")
        h.add("Two", command: "echo 2")
        h.model.hud.setInput("x")  // text: autocomplete owns ↑ ↓
        #expect(!h.model.moveCommandSelection(by: 1))
        h.model.hud.setInput("")
        h.model.hud.selectTab(.services)
        #expect(!h.model.moveCommandSelection(by: 1))
        #expect(h.terminals.ran.isEmpty)
    }

    @Test func aClickMovesTheSelectionAndOpeningTheTabResetsIt() async throws {
        let h = try CommandsHarness()
        h.add("One", command: "echo 1")
        let two = h.add("Two", command: "echo 2")
        h.model.hud.selectTab(.commands)
        h.model.activateCommand(two)
        #expect(selected(h) == ["Two"])
        await waitForRun(h)
        #expect(h.terminals.ran == [.script(.terminal, directory: h.work.path, command: " echo 2")])
        h.model.hud.selectTab(.commands)  // the HUD closed after the run; opening the tab again
        #expect(selected(h) == ["One"])
    }

    @Test func commandReturnOnACommandThatCantRunOpensItsForm() throws {
        let h = try CommandsHarness(file: #"{ "commands": [ { "id": "a", "name": "Bad", "command": " " } ] }"#)
        h.model.hud.selectTab(.commands)
        #expect(selected(h) == ["Bad"])
        #expect(h.model.handleShortcut(commandReturn))
        #expect(h.model.hud.tab == .settings && h.model.hud.settingsSection == .commands)
        #expect(h.commands.settingsScreen.form != nil)
        #expect(h.terminals.ran.isEmpty)
    }

    @Test func theFooterNamesTheKeysWhileThereAreCommands() throws {
        let empty = try CommandsHarness()
        empty.model.hud.selectTab(.commands)
        #expect(empty.model.footerLeft == .hints(Strings.Hints.otherTabEmpty))  // no commands
        // Read from the file, so no "Added …" toast takes the footer.
        let h = try CommandsHarness(
            file: #"{ "commands": [ { "id": "a", "name": "Logs", "command": "tail -f log", "cwd": "~" } ] }"#)
        h.model.hud.selectTab(.commands)
        #expect(h.model.footerLeft == .hints(Strings.Hints.commandsList))
        #expect(
            Strings.Hints.commandsList == [
                Hint(keys: ["↑↓"], label: "choose"), Hint(keys: ["⌘↩"], label: "run"),
                Hint(keys: ["esc"], label: "close"),
            ])
        h.model.hud.setInput("ss")
        #expect(h.model.footerLeft != .hints(Strings.Hints.commandsList))
    }
}
