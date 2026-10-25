import Foundation

/// The fields of the command form as the user types them. Nothing happens until Save.
public struct CommandDraft: Equatable, Sendable {
    public var name = ""
    public var command = ""
    /// The folder; `~` stands for the home folder.
    public var cwd = "~"

    public init() {}

    init(_ definition: CommandDefinition) {
        name = definition.name
        command = definition.command
        cwd = definition.cwd
    }
}

/// The editor in Settings → Commands, while open (contract, slice 6).
public struct CommandForm: Equatable, Sendable {
    /// The command being edited; nil for a new one.
    public let editing: CommandDefinition.ID?
    public internal(set) var draft: CommandDraft
    /// The question in the form's bottom bar.
    public internal(set) var bar: Bar = .none
    /// The problems from the last Save, by field. A field's problem goes when it is edited.
    public internal(set) var problems: [CommandField: String] = [:]
    /// The draft as it was when the form opened.
    let original: CommandDraft

    public enum Bar: Equatable, Sendable {
        case none
        /// "Discard your changes?", after Cancel, Back or Esc with changes.
        case discard
        /// "Remove SSH into staging?", after Remove….
        case remove
    }

    init(editing: CommandDefinition.ID?, draft: CommandDraft) {
        self.editing = editing
        self.draft = draft
        original = draft
    }

    public var isDirty: Bool { draft != original }
}

/// Settings → Commands, ready to draw (contract, slice 6): the list, or the open form.
public struct CommandsSettingsScreen: Equatable, Sendable {
    public let title: String
    public let intro: String
    public let fileProblem: FileProblemCard?
    public let rows: [Row]
    /// Shown in place of the rows when there are no commands.
    public let emptyCard: String?
    public let add: String
    /// False while commands.json can't be used.
    public let addEnabled: Bool
    /// The open form, drawn in place of the list.
    public let form: CommandFormScreen?

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: CommandDefinition.ID
        public let name: String
        /// "ssh deploy@staging.example.dev · ~"
        public let commandLine: String
    }
}

/// The command form, ready to draw. Its labels are in `Strings.CommandForm`.
public struct CommandFormScreen: Equatable, Sendable {
    /// "New command", or the command's name.
    public let title: String
    public let back: String
    public let name: String
    public let command: String
    public let cwd: String
    /// Under each field, in --danger.
    public let problems: [CommandField: String]
    /// The bottom bar, in --danger: "Couldn't save: The disk is full."
    public let saveProblem: String?
    public let saveEnabled: Bool
    /// "Remove…"; nil for a new command.
    public let remove: String?
    public let bar: FormBar
}

extension CommandStore {
    // MARK: The form's intents

    /// Opens the form on a command, or on a new one for nil. Not while commands.json can't be
    /// used. A command read from the file that breaks a rule opens with its problems shown.
    public func editCommand(_ id: CommandDefinition.ID?) {
        guard canEdit else { return }
        if let id {
            guard let definition = definition(id) else { return }
            form = CommandForm(editing: id, draft: CommandDraft(definition))
            form?.problems = definition.problems
        } else {
            form = CommandForm(editing: nil, draft: CommandDraft())
        }
    }

    /// Any change to the draft. A changed field's problem goes.
    public func updateDraft(_ edit: (inout CommandDraft) -> Void) {
        guard var form else { return }
        let before = form.draft
        edit(&form.draft)
        if before.name != form.draft.name { form.problems[.name] = nil }
        if before.command != form.draft.command { form.problems[.command] = nil }
        if before.cwd != form.draft.cwd { form.problems[.cwd] = nil }
        self.form = form
    }

    /// Save: saves the draft with `save(_:)`. The form closes when it is saved, and otherwise
    /// stays open with the problems.
    public func saveForm() {
        guard var form else { return }
        let draft = form.draft
        let problems = save(
            CommandDefinition(
                id: form.editing ?? UUID().uuidString, name: draft.name, command: draft.command, cwd: draft.cwd))
        guard !problems.isEmpty else {
            self.form = nil
            return
        }
        form.problems = problems
        form.bar = .none
        self.form = form
    }

    /// Cancel, Back or Esc: closes the bar if one shows, asks first if the draft has changes,
    /// or closes the form.
    public func cancelForm() {
        guard var form else { return }
        if form.bar != .none {
            form.bar = .none
        } else if form.isDirty {
            form.bar = .discard
        } else {
            self.form = nil
            return
        }
        self.form = form
    }

    /// Discard, on the discard bar.
    public func discardForm() {
        form = nil
    }

    /// Remove…: asks first, in the bar.
    public func askRemove() {
        guard form?.editing != nil else { return }
        form?.bar = .remove
    }

    /// Remove, on the remove bar. The form stays open with the problem if it couldn't be removed.
    public func confirmRemove() {
        guard var form, let id = form.editing, form.bar == .remove else { return }
        let problems = delete(id)
        guard !problems.isEmpty else {
            self.form = nil
            return
        }
        form.problems = problems
        form.bar = .none
        self.form = form
    }

    /// Keep editing, on the discard bar, or Cancel, on the remove bar.
    public func dismissBar() {
        form?.bar = .none
    }

    /// The folder the user chose, written into the draft: under the home folder it is `~/…`.
    func setDraftFolder(_ path: String) {
        let folder = path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        updateDraft { $0.cwd = String(folder) }
    }

    // MARK: Settings → Commands

    public var settingsScreen: CommandsSettingsScreen {
        CommandsSettingsScreen(
            title: Strings.SettingsSections.title(.commands), intro: Strings.CommandForm.intro,
            fileProblem: loadError.map { FileProblemCard($0, kind: .commands) },
            rows: definitions.map {
                CommandsSettingsScreen.Row(
                    id: $0.id, name: $0.name,
                    commandLine: Strings.Services.actionSubtitle(command: $0.command, cwd: $0.cwd))
            },
            emptyCard: definitions.isEmpty && loadError == nil ? Strings.CommandForm.empty : nil,
            add: Strings.CommandForm.add, addEnabled: canEdit, form: form.map(formScreen))
    }

    private func formScreen(_ form: CommandForm) -> CommandFormScreen {
        let editing = form.editing.flatMap(definition)
        let bar: FormBar
        switch form.bar {
        case .none:
            bar = .none
        case .discard:
            bar = .discard(
                question: Strings.ListForm.discardQuestion, keep: Strings.ListForm.keepEditing,
                discard: Strings.ListForm.discard)
        case .remove:
            bar = .remove(
                question: Strings.ListForm.removeQuestion(editing?.name ?? ""), cancel: Strings.ListForm.cancel,
                remove: Strings.ListForm.removeConfirm)
        }
        var fieldProblems = form.problems
        let saveProblem = fieldProblems.removeValue(forKey: .file)
        return CommandFormScreen(
            title: editing?.name ?? Strings.CommandForm.newTitle, back: Strings.CommandForm.back,
            name: form.draft.name, command: form.draft.command, cwd: form.draft.cwd, problems: fieldProblems,
            saveProblem: saveProblem, saveEnabled: canEdit,
            remove: form.editing == nil ? nil : Strings.ListForm.remove, bar: bar)
    }
}
