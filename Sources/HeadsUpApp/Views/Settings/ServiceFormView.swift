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
            FormBackButton(title: form.back, back: services.cancelForm)
            SettingsTitle(text: form.title)
            if let note = form.runningNote {
                Text(note)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
            }

            FormField(label: Strings.ListForm.name, problem: form.problems[.name]) {
                TextField(
                    Strings.ListForm.name, text: draft(form.name) { $0.name = $1 },
                    prompt: Text(Strings.ServiceForm.namePlaceholder)
                )
                .onSubmit(services.saveForm)
            }
            FormField(
                label: Strings.ListForm.command, help: Strings.ServiceForm.commandHelp,
                problem: form.problems[.command]
            ) {
                TextField(
                    Strings.ListForm.command, text: draft(form.command) { $0.command = $1 },
                    prompt: Text(Strings.ServiceForm.commandPlaceholder)
                )
                .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                .onSubmit(services.saveForm)
            }
            FormField(label: Strings.ListForm.folder, problem: form.problems[.cwd]) {
                FolderRow(path: form.cwd, chooseTitle: Strings.ListForm.choose) { model.chooseServiceFolder() }
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
            FormCheckbox(
                title: Strings.ServiceForm.autostart, help: Strings.ServiceForm.autostartHelp, isOn: form.autostart
            ) { on in services.updateDraft { $0.autostart = on } }
            FormCheckbox(
                title: Strings.ServiceForm.keepAwake, help: Strings.ServiceForm.keepAwakeHelp, isOn: form.keepAwake
            ) { on in services.updateDraft { $0.keepAwake = on } }
            FormCheckbox(
                title: Strings.ServiceForm.restartOnExit, help: Strings.ServiceForm.restartOnExitHelp,
                isOn: form.restartOnExit
            ) { on in services.updateDraft { $0.restartOnExit = on } }

            Hairline()
            FormBottomBar(
                bar: form.bar, saveProblem: form.saveProblem, saveEnabled: form.saveEnabled, remove: form.remove,
                actions: FormBarActions(
                    askRemove: services.askRemove, cancel: services.cancelForm, save: services.saveForm,
                    dismissBar: services.dismissBar, discard: services.discardForm,
                    confirmRemove: services.confirmRemove))
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

/// A checkbox with its help under it, in 12 pt secondary text, as the macOS form style has
/// them. VoiceOver reads the title as the label and the help as the hint (UX: service flags §6).
private struct FormCheckbox: View {
    let title: String
    let help: String
    let isOn: Bool
    let set: @MainActor (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityHint(help)
    }
}
