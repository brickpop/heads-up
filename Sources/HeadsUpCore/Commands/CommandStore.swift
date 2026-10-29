import Foundation
import Observation

/// Commands (ADR-001 §6.2, §7.3; Commands spec): the commands in commands.json, the terminal
/// they open in, and the editor.
///
/// Running a command is `AppModel.runCommand(_:)`, which also handles the HUD around the
/// Automation prompt; it calls `run(_:)` here.
@MainActor
@Observable
public final class CommandStore {
    public private(set) var definitions: [CommandDefinition] = []
    /// Why commands.json can't be used. While set, the editor is off and the file is never written.
    public private(set) var loadError: ListFileProblem?
    /// The terminal apps installed, as last found by `refreshTerminals()`.
    public private(set) var terminals: [InstalledTerminal] = []
    /// Why the last run of a command didn't open, shown under its row until it runs again or
    /// the terminal changes. Never `.opened`.
    public private(set) var runProblem: [CommandDefinition.ID: TerminalRunResult] = [:]
    /// The editor in Settings → Commands, while open (see CommandForm.swift).
    public internal(set) var form: CommandForm?

    @ObservationIgnored private let file: JSONListFile<CommandDefinition>
    @ObservationIgnored private let launcher: TerminalLauncher
    @ObservationIgnored private let files: FileRevealer
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private weak var toaster: Toaster?
    @ObservationIgnored private let loginShell: String
    @ObservationIgnored let home: String

    public init(
        folder: URL?, launcher: TerminalLauncher, files: FileRevealer, settings: SettingsStore, toaster: Toaster,
        loginShell: String, home: String
    ) {
        file = JSONListFile(.commands, folder: folder)
        self.launcher = launcher
        self.files = files
        self.settings = settings
        self.toaster = toaster
        self.loginShell = loginShell
        self.home = home
        load()
        refreshTerminals()
    }

    // MARK: Terminals

    /// The terminals a command can open in: the installed ones that can run a command
    /// (not Warp, which has no way to; Sally msg-484).
    public var offeredTerminals: [InstalledTerminal] {
        terminals.filter { $0.terminal != .warp }
    }

    /// The terminal commands open in: the one in Settings if it is installed, else the first.
    public var terminal: InstalledTerminal? {
        let chosen = settings.settings.general.terminalBundleID
        return offeredTerminals.first { $0.terminal.bundleID == chosen } ?? offeredTerminals.first
    }

    /// Looks for terminal apps again. AppModel calls it when Commands or Settings opens.
    public func refreshTerminals() {
        let found = launcher.installed()
        if found != terminals { terminals = found }
    }

    /// The picker's choice, by bundle id: written into settings.json. An app that isn't
    /// offered is ignored.
    public func setTerminal(_ bundleID: String) {
        guard offeredTerminals.contains(where: { $0.terminal.bundleID == bundleID }) else { return }
        settings.update { $0.general.terminalBundleID = bundleID }
        runProblem = [:]
    }

    // MARK: Running

    /// Opens the command in the chosen terminal. Returns nil when there was nothing to run (no
    /// such command, one that breaks a rule, or no terminal).
    func run(_ id: CommandDefinition.ID) async -> TerminalRunResult? {
        guard let definition = definition(id), definition.problems.isEmpty, let terminal,
            let plan = TerminalPlan.make(definition, in: terminal, loginShell: loginShell, home: home)
        else { return nil }
        runProblem[id] = nil
        let result = await launcher.run(plan)
        // An opened command shows no toast: the HUD closes at once (AppModel.runCommand).
        if result != .opened, self.definition(id) != nil {
            runProblem[id] = result
        }
        return result
    }

    // MARK: Editing

    /// Saves a command: adds a new one or replaces the one with the same id. Returns the
    /// problems that kept it from being saved, by field; empty when it was saved. A file that
    /// couldn't be written is a `.file` problem, and nothing changes, on disk or here.
    @discardableResult
    public func save(_ definition: CommandDefinition) -> [CommandField: String] {
        guard canEdit else { return [.file: Strings.ListFile.cantEdit(.commands)] }
        var problems = definition.problems
        var isFolder: ObjCBool = false
        let folder = SpawnPlan.expand(definition.cwd, home: home)
        if problems[.cwd] == nil,
            !FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) || !isFolder.boolValue
        {
            problems[.cwd] = Strings.ListForm.folderMissing
        }
        guard problems.isEmpty else { return problems }

        var trimmed = definition
        trimmed.name = definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = definitions
        let isNew: Bool
        if let index = list.firstIndex(where: { $0.id == definition.id }) {
            list[index] = trimmed
            isNew = false
        } else {
            list.append(trimmed)
            isNew = true
        }
        if let problem = file.write(list) { return [.file: problem] }
        definitions = list
        runProblem[definition.id] = nil
        toaster?.toast(isNew ? Strings.Commands.added(trimmed.name) : Strings.Commands.saved(trimmed.name))
        return [:]
    }

    /// Remove…, confirmed. Returns the problem that kept it from being removed, as `save` does.
    @discardableResult
    public func delete(_ id: CommandDefinition.ID) -> [CommandField: String] {
        guard canEdit else { return [.file: Strings.ListFile.cantEdit(.commands)] }
        guard let definition = definition(id) else { return [:] }
        let list = definitions.filter { $0.id != id }
        if let problem = file.write(list) { return [.file: problem] }
        definitions = list
        runProblem[id] = nil
        toaster?.toast(Strings.Commands.removed(definition.name))
        return [:]
    }

    /// Whether the editor may change commands.json (not while it can't be used).
    public var canEdit: Bool { loadError == nil }

    // MARK: commands.json problems

    /// Show in Finder, on the commands.json problem card.
    public func revealCommandsFile() {
        guard let url = file.url else { return }
        files.reveal(url)
    }

    /// Try Again, on the card: reads commands.json again, only while it can't be used.
    public func reloadCommands() {
        guard loadError != nil else { return }
        loadError = nil
        load()
    }

    // MARK: Inside

    func definition(_ id: CommandDefinition.ID) -> CommandDefinition? {
        definitions.first { $0.id == id }
    }

    private func load() {
        switch file.load() {
        case .success(let list): definitions = list
        case .failure(let problem):
            definitions = []
            loadError = problem
        }
    }
}
