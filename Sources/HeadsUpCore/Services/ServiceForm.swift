import Foundation

/// The fields of the service form as the user types them. Nothing happens until Save.
public struct ServiceDraft: Equatable, Sendable {
    public var name = ""
    public var command = ""
    /// The folder; `~` stands for the home folder.
    public var cwd = "~"
    public var env: [EnvironmentVariable] = []
    /// As typed: empty for none.
    public var port = ""
    public var autostart = false
    public var keepAwake = ServiceKeepAwake.off
    public var restartOnExit = false

    public init() {}

    init(_ definition: ServiceDefinition) {
        name = definition.name
        command = definition.command
        cwd = definition.cwd
        env = definition.env
        port = definition.port.map(String.init) ?? ""
        autostart = definition.autostart
        keepAwake = definition.keepAwake
        restartOnExit = definition.restartOnExit
    }

    /// The draft as a service, or the port problem when the port isn't a number.
    func definition(id: ServiceDefinition.ID) -> Result<ServiceDefinition, PortNotANumber> {
        let typed = port.trimmingCharacters(in: .whitespaces)
        var number: Int?
        if !typed.isEmpty {
            guard let parsed = Int(typed) else { return .failure(PortNotANumber()) }
            number = parsed
        }
        return .success(
            ServiceDefinition(
                id: id, name: name, command: command, cwd: cwd, env: env, port: number, autostart: autostart,
                keepAwake: keepAwake, restartOnExit: restartOnExit))
    }

    struct PortNotANumber: Error {}
}

/// The editor in Settings → Services, while open (contract, slice 5).
public struct ServiceForm: Equatable, Sendable {
    /// The service being edited; nil for a new one.
    public let editing: ServiceDefinition.ID?
    public internal(set) var draft: ServiceDraft
    /// The question in the form's bottom bar.
    public internal(set) var bar: Bar = .none
    /// The problems from the last Save, by field. A field's problem goes when it is edited.
    public internal(set) var problems: [ServiceField: String] = [:]
    /// The draft as it was when the form opened.
    let original: ServiceDraft

    public enum Bar: Equatable, Sendable {
        case none
        /// "Discard your changes?", after Cancel, Back or Esc with changes.
        case discard
        /// "Remove Web dev server?", after Remove….
        case remove
    }

    init(editing: ServiceDefinition.ID?, draft: ServiceDraft) {
        self.editing = editing
        self.draft = draft
        original = draft
    }

    public var isDirty: Bool { draft != original }
}

/// Settings → Services, ready to draw (contract, slice 5): the list, or the open form.
public struct ServicesSettingsScreen: Equatable, Sendable {
    public let title: String
    public let intro: String
    /// A lasting 12 pt line under the intro while services run with HeadsUp's permissions,
    /// still shown after the tab's notice is dismissed (R10).
    public let isolationLine: String?
    public let fileProblem: FileProblemCard?
    /// "You can't change services until `services.json` can be read.", while it can't.
    public let cantEditLine: String?
    public let rows: [Row]
    /// Shown in place of the rows when there are no services.
    public let emptyCard: String?
    public let add: String
    /// False while services.json can't be used.
    public let addEnabled: Bool
    /// The open form, drawn in place of the list.
    public let form: ServiceFormScreen?

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: ServiceDefinition.ID
        public let name: String
        /// "npm run dev · ~/code/web-app"
        public let commandLine: String
    }
}

/// The service form, ready to draw. Its labels are in `Strings.ServiceForm`.
public struct ServiceFormScreen: Equatable, Sendable {
    /// "New service", or the service's name.
    public let title: String
    public let back: String
    /// "Changes to the command, folder or environment apply the next time it starts.", while
    /// the service runs.
    public let runningNote: String?
    public let name: String
    public let command: String
    public let cwd: String
    public let env: [EnvironmentVariable]
    public let port: String
    public let autostart: Bool
    /// Keep awake: Off · 30m · 2h · 5h · Unlimited, under Start with HeadsUp.
    public let keepAwake: ServiceKeepAwake
    /// "Restart if it stops", under Keep awake.
    public let restartOnExit: Bool
    /// Under each field, in --danger.
    public let problems: [ServiceField: String]
    /// The bottom bar, in --danger: "Couldn't save: The disk is full."
    public let saveProblem: String?
    public let saveEnabled: Bool
    /// "Remove…"; nil for a new service.
    public let remove: String?
    public let bar: FormBar
}

extension ServiceStore {
    // MARK: The form's intents

    /// Opens the form on a service, or on a new one for nil. Not while services.json can't be used.
    public func editService(_ id: ServiceDefinition.ID?) {
        guard canEdit else { return }
        if let id {
            guard let definition = definition(id) else { return }
            // A service read from services.json that breaks a rule opens with its problems shown.
            form = ServiceForm(editing: id, draft: ServiceDraft(definition))
            form?.problems = definition.problems
        } else {
            form = ServiceForm(editing: nil, draft: ServiceDraft())
        }
    }

    /// Any change to the draft. A changed field's problem goes.
    public func updateDraft(_ edit: (inout ServiceDraft) -> Void) {
        guard var form else { return }
        let before = form.draft
        edit(&form.draft)
        let after = form.draft
        if before.name != after.name { form.problems[.name] = nil }
        if before.command != after.command { form.problems[.command] = nil }
        if before.cwd != after.cwd { form.problems[.cwd] = nil }
        if before.env != after.env { form.problems[.env] = nil }
        if before.port != after.port { form.problems[.port] = nil }
        self.form = form
    }

    /// Save: checks the draft, then saves it with `save(_:)`. The form closes when it is saved,
    /// and otherwise stays open with the problems.
    public func saveForm() {
        guard var form else { return }
        let id = form.editing ?? UUID().uuidString
        var problems: [ServiceField: String]
        switch form.draft.definition(id: id) {
        case .success(let definition):
            problems = save(definition)
        case .failure:
            // The other fields' problems too, so one Save shows them all.
            let definition = ServiceDefinition(
                id: id, name: form.draft.name, command: form.draft.command, cwd: form.draft.cwd, env: form.draft.env)
            problems = definition.problems
            problems[.port] = Strings.Services.portProblem
        }
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
        let folder =
            path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        updateDraft { $0.cwd = String(folder) }
    }

    // MARK: Settings → Services

    public var settingsScreen: ServicesSettingsScreen {
        ServicesSettingsScreen(
            title: Strings.SettingsSections.title(.services), intro: Strings.ServiceForm.intro,
            isolationLine: isolationWarning ? Strings.Services.isolationTitle : nil,
            fileProblem: loadError.map { FileProblemCard($0, kind: .services) },
            cantEditLine: canEdit ? nil : Strings.ListFile.cantEdit(.services),
            rows: definitions.map {
                ServicesSettingsScreen.Row(
                    id: $0.id, name: $0.name,
                    commandLine: Strings.Services.actionSubtitle(command: $0.command, cwd: $0.cwd))
            },
            emptyCard: definitions.isEmpty && loadError == nil ? Strings.ServiceForm.empty : nil,
            add: Strings.ServiceForm.add, addEnabled: canEdit, form: form.map(formScreen))
    }

    private func formScreen(_ form: ServiceForm) -> ServiceFormScreen {
        let editing = form.editing.flatMap(definition)
        let name = editing?.name ?? ""
        let bar: FormBar
        switch form.bar {
        case .none:
            bar = .none
        case .discard:
            bar = .discard(
                question: Strings.ListForm.discardQuestion, keep: Strings.ListForm.keepEditing,
                discard: Strings.ListForm.discard)
        case .remove:
            let isLive = form.editing.map { state($0).isLive } ?? false
            bar = .remove(
                question: isLive ? Strings.ServiceForm.removeRunning(name) : Strings.ListForm.removeQuestion(name),
                cancel: Strings.ListForm.cancel, remove: Strings.ListForm.removeConfirm)
        }
        var fieldProblems = form.problems
        let saveProblem = fieldProblems.removeValue(forKey: .file)
        return ServiceFormScreen(
            title: editing?.name ?? Strings.ServiceForm.newTitle, back: Strings.ServiceForm.back,
            runningNote: form.editing.map { state($0).isLive } == true ? Strings.ServiceForm.runningNote : nil,
            name: form.draft.name, command: form.draft.command, cwd: form.draft.cwd, env: form.draft.env,
            port: form.draft.port, autostart: form.draft.autostart, keepAwake: form.draft.keepAwake,
            restartOnExit: form.draft.restartOnExit, problems: fieldProblems,
            saveProblem: saveProblem, saveEnabled: canEdit,
            remove: form.editing == nil ? nil : Strings.ListForm.remove, bar: bar)
    }
}
