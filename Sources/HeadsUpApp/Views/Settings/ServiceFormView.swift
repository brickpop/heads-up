import HeadsUpCore
import SwiftUI

/// The service form, in place of the list: ‹ Services, the title, the fields with their
/// problems under them, and the bottom bar (Remove…, Cancel, Save), which turns into the
/// discard or remove question. Every edit goes to the core's draft.
struct ServiceFormView: View {
    let model: AppModel
    let form: ServiceFormScreen

    var body: some View {
        let services = model.services
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            Button(action: services.cancelForm) {
                Label(form.back, systemImage: Symbols.back)
            }
            .buttonStyle(.borderless)
            SettingsTitle(text: form.title)
            if let note = form.runningNote {
                Text(note)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
            }

            FormField(label: Strings.ServiceForm.name, problem: form.problems[.name]) {
                TextField(
                    Strings.ServiceForm.name, text: draft(form.name) { $0.name = $1 },
                    prompt: Text(Strings.ServiceForm.namePlaceholder)
                )
                .onSubmit(services.saveForm)
            }
            FormField(
                label: Strings.ServiceForm.command, help: Strings.ServiceForm.commandHelp,
                problem: form.problems[.command]
            ) {
                TextField(
                    Strings.ServiceForm.command, text: draft(form.command) { $0.command = $1 },
                    prompt: Text(Strings.ServiceForm.commandPlaceholder)
                )
                .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                .onSubmit(services.saveForm)
            }
            FormField(label: Strings.ServiceForm.folder, problem: form.problems[.cwd]) {
                HStack {
                    Text(form.cwd)
                        .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(Strings.ServiceForm.choose) { model.chooseServiceFolder() }
                        .buttonStyle(.bordered)
                }
            }
            FormField(label: Strings.ServiceForm.environment, problem: form.problems[.env]) {
                EnvironmentEditor(services: services, env: form.env)
            }
            FormField(
                label: Strings.ServiceForm.port, help: Strings.ServiceForm.portHelp, problem: form.problems[.port]
            ) {
                TextField(Strings.ServiceForm.port, text: draft(form.port) { $0.port = $1 })
                    .frame(width: HUDStyle.ServiceForm.portWidth)
                    .onSubmit(services.saveForm)
            }
            Toggle(
                isOn: Binding(get: { form.autostart }, set: { on in services.updateDraft { $0.autostart = on } })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.ServiceForm.autostart)
                    Text(Strings.ServiceForm.autostartHelp)
                        .font(.system(size: HUDStyle.Settings.helpSize))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Hairline()
            ServiceFormBar(services: services, form: form)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: HUDStyle.Settings.labelSize))
    }

    /// A text binding to one field of the core's draft.
    private func draft(
        _ value: String, _ write: @escaping (inout ServiceDraft, String) -> Void
    ) -> Binding<String> {
        Binding(get: { value }, set: { text in model.services.updateDraft { write(&$0, text) } })
    }
}

/// A labelled field, with optional help under it, and its problem in red.
private struct FormField<Field: View>: View {
    let label: String
    var help: String?
    let problem: String?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            Text(label)
                .font(.system(size: HUDStyle.Settings.helpSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .accessibilityLabel(label)
            if let help {
                Text(help)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                ProblemNote(text: problem)
            }
        }
    }
}

/// The environment variables: one row of mono key and value per variable, − to remove it,
/// + to add one, then the plain-file warning (F11) and the secrets hint.
private struct EnvironmentEditor: View {
    let services: ServiceStore
    let env: [EnvironmentVariable]

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            if env.isEmpty {
                Text(Strings.ServiceForm.noVariables)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(env.enumerated()), id: \.offset) { index, row in
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    TextField(
                        Strings.ServiceForm.variableName,
                        text: Binding(
                            get: { row.key },
                            set: { key in
                                services.updateDraft { if $0.env.indices.contains(index) { $0.env[index].key = key } }
                            }
                        ),
                        prompt: Text(Strings.ServiceForm.keyPlaceholder)
                    )
                    .frame(width: HUDStyle.ServiceForm.envKeyWidth)
                    .accessibilityLabel(Strings.ServiceForm.variableName)
                    TextField(
                        Strings.ServiceForm.variableValue(row.key),
                        text: Binding(
                            get: { row.value },
                            set: { value in
                                services.updateDraft {
                                    if $0.env.indices.contains(index) { $0.env[index].value = value }
                                }
                            }
                        ),
                        prompt: Text(Strings.ServiceForm.valuePlaceholder)
                    )
                    .accessibilityLabel(Strings.ServiceForm.variableValue(row.key))
                    Button {
                        services.updateDraft { if $0.env.indices.contains(index) { $0.env.remove(at: index) } }
                    } label: {
                        Image(systemName: Symbols.minus)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Strings.ServiceForm.removeVariable)
                }
                .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
            }
            Button {
                services.updateDraft { $0.env.append(EnvironmentVariable(key: "", value: "")) }
            } label: {
                Image(systemName: Glyph.plus.symbolName)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Strings.ServiceForm.addVariable)
            Text(Strings.ServiceForm.environmentWarning)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(HUDStyle.Colors.warn)
            InlineMarkdownText(Strings.ServiceForm.environmentHint)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The bottom bar: Remove… on the left, Cancel and Save on the right, and a save problem;
/// or, in its place, the discard or remove question.
private struct ServiceFormBar: View {
    let services: ServiceStore
    let form: ServiceFormScreen

    var body: some View {
        switch form.bar {
        case .none:
            VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
                if let problem = form.saveProblem {
                    ProblemNote(text: problem)
                }
                HStack {
                    if let remove = form.remove {
                        Button(action: services.askRemove) {
                            Text(remove).foregroundStyle(HUDStyle.Colors.alert)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(Strings.ServiceForm.cancel, action: services.cancelForm)
                        .buttonStyle(.bordered)
                    Button(Strings.ServiceForm.save, action: services.saveForm)
                        .buttonStyle(.borderedProminent)
                        .disabled(!form.saveEnabled)
                }
            }
        case .discard(let question, let keep, let discard):
            questionBar(
                question,
                actions: {
                    Button(keep, action: services.dismissBar)
                        .buttonStyle(.bordered)
                    Button(discard, action: services.discardForm)
                        .buttonStyle(.borderless)
                })
        case .remove(let question, let cancel, let remove):
            questionBar(
                question,
                actions: {
                    Button(cancel, action: services.dismissBar)
                        .buttonStyle(.bordered)
                    Button(action: services.confirmRemove) {
                        Text(remove).foregroundStyle(HUDStyle.Colors.alert)
                    }
                    .buttonStyle(.borderless)
                })
        }
    }

    /// The question on the left and its buttons on the right, in place of the bar.
    private func questionBar(_ text: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions()
        }
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}
