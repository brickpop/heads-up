import Foundation

/// What the Commands tab shows, ready to draw (contract, slice 6).
public struct CommandsScreen: Equatable, Sendable {
    /// "Command shortcuts"
    public let label: String
    /// "Opens in" and the installed terminals; nil with one terminal or none.
    public let terminalPicker: TerminalPicker?
    /// The header's "Edit…": `AppModel.openCommandsSettings()`.
    public let edit: String
    /// While commands.json can't be used: shown in place of the list or the empty state.
    public let fileProblem: FileProblemCard?
    /// Shown in place of the list when there are no commands.
    public let empty: Empty?
    public let rows: [Row]

    public struct Empty: Equatable, Sendable {
        public let title: String
        public let text: String
        /// "Add a command…": `AppModel.addCommand()`.
        public let add: String
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: CommandDefinition.ID
        public let name: String
        /// Mono, --ink-2.
        public let command: String
        /// Mono, --ink-3: "~/code/web-app".
        public let cwd: String
        /// The pill: the terminal it opens in, "iTerm2".
        public let terminal: String
        /// "Can't run · enter a command to run", in --warn, for a command from commands.json
        /// that breaks a rule; nil otherwise.
        public let meta: String?
        /// What a click on the row does.
        public let action: RowAction
        /// VoiceOver: the name, then "ssh deploy@staging.example.dev, in home folder", then
        /// "Opens in iTerm2".
        public let accessibilityLabel: String
        public let accessibilityValue: String
        public let accessibilityHint: String
        /// Why it didn't open, under the row, in place of the toast. VoiceOver announces it.
        public let problem: RowProblem?
    }

    public enum RowAction: Equatable, Sendable {
        /// `AppModel.runCommand(id)`.
        case run
        /// The pill is replaced by this small secondary button; the row opens the form:
        /// `AppModel.editCommand(id)`.
        case edit(title: String)
    }

    public struct RowProblem: Equatable, Sendable {
        public let text: String
        public let fix: Fix
    }

    /// The small ghost button under a run problem.
    public struct Fix: Equatable, Sendable {
        public let kind: FixKind
        public let title: String
    }

    public enum FixKind: Equatable, Sendable {
        /// "Open System Settings": `AppModel.openAutomationSettings()`.
        case openAutomation
        /// "Open Settings": `AppModel.openTerminalSetting()`, Settings → General.
        case openGeneral
        /// "Try Again": `AppModel.runCommand(id)`.
        case tryAgain
    }
}

/// The terminal apps a command can open in, as a control in the Commands tab and a row in
/// Settings → General. A choice is `CommandStore.setTerminal(id)`.
public struct TerminalPicker: Equatable, Sendable {
    /// "Opens in", or "Terminal app".
    public let label: String
    public let choices: [TerminalChoice]
    /// The chosen terminal's bundle id.
    public let selectedID: String
    public let style: Style

    public enum Style: Equatable, Sendable {
        /// Up to 3 terminals.
        case segmented
        /// More than 3: a pop-up menu.
        case menu
    }
}

public struct TerminalChoice: Equatable, Sendable, Identifiable {
    /// The app's bundle id.
    public let id: String
    public let title: String
    public let isSelected: Bool
}

extension CommandStore {
    /// The Commands tab.
    public var screen: CommandsScreen {
        CommandsScreen(
            label: Strings.Commands.tabLabel, terminalPicker: picker(label: Strings.Commands.opensIn),
            edit: Strings.Commands.edit, fileProblem: loadError.map { FileProblemCard($0, kind: .commands) },
            empty: definitions.isEmpty && loadError == nil
                ? CommandsScreen.Empty(
                    title: Strings.Commands.emptyTitle, text: Strings.Commands.emptyText,
                    add: Strings.Commands.addCommand)
                : nil,
            rows: definitions.map(row))
    }

    /// The Terminal app row in Settings → General; nil with one terminal or none.
    public var terminalSetting: TerminalPicker? {
        picker(label: Strings.Commands.terminalApp)
    }

    /// The most terminals a segmented control shows; more use a menu (Yuki).
    static let segmentedLimit = 3

    private func picker(label: String) -> TerminalPicker? {
        let offered = offeredTerminals
        guard offered.count > 1, let selected = terminal?.terminal else { return nil }
        return TerminalPicker(
            label: label,
            choices: offered.map {
                TerminalChoice(id: $0.terminal.bundleID, title: $0.terminal.name, isSelected: $0.terminal == selected)
            }, selectedID: selected.bundleID, style: offered.count <= Self.segmentedLimit ? .segmented : .menu)
    }

    private func row(_ definition: CommandDefinition) -> CommandsScreen.Row {
        let terminalName = terminal?.terminal.name ?? ""
        // A command read from commands.json that breaks a rule can't run until it is fixed.
        let rule = [CommandField.name, .command, .cwd].lazy.compactMap { definition.problems[$0] }.first
        var problem: CommandsScreen.RowProblem?
        if rule == nil, let result = runProblem[definition.id] {
            problem = CommandsScreen.RowProblem(
                text: Strings.Commands.runProblem(result, terminal: terminalName), fix: Self.fix(for: result))
        }
        return CommandsScreen.Row(
            id: definition.id, name: definition.name, command: definition.command, cwd: definition.cwd,
            terminal: terminalName, meta: rule.map(Strings.Commands.cantRun),
            action: rule == nil ? .run : .edit(title: Strings.Commands.edit), accessibilityLabel: definition.name,
            accessibilityValue: Strings.Commands.accessibilityValue(command: definition.command, cwd: definition.cwd),
            accessibilityHint: Strings.Commands.accessibilityHint(terminal: terminalName), problem: problem)
    }

    static func fix(for result: TerminalRunResult) -> CommandsScreen.Fix {
        switch result {
        case .notAllowed: CommandsScreen.Fix(kind: .openAutomation, title: Strings.Commands.openSystemSettings)
        case .notInstalled: CommandsScreen.Fix(kind: .openGeneral, title: Strings.Commands.openSettings)
        case .failed, .opened: CommandsScreen.Fix(kind: .tryAgain, title: Strings.Commands.tryAgain)
        }
    }
}

/// The Commands section of the action catalogue: Run <name> for each command. A model may
/// never suggest it (F1).
@MainActor
enum CommandActions {
    static func make(commands: CommandStore, run: @escaping @MainActor (CommandDefinition.ID) -> Void) -> [Action] {
        commands.definitions.filter { $0.problems.isEmpty }.map { definition in
            let id = definition.id
            return Action(
                id: ActionID("command.run:\(id)"), title: Strings.Commands.runAction(definition.name),
                subtitle: Strings.Services.actionSubtitle(command: definition.command, cwd: definition.cwd),
                kind: .command, glyph: .terminal, keywords: "command terminal run open shell \(definition.command)",
                suggest: .never, run: { run(id) })
        }
    }
}
