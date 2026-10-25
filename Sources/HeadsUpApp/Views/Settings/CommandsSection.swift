import HeadsUpCore
import SwiftUI

/// Settings → Commands: the list of commands, or the form of the one being edited, in the
/// same list-and-form pattern as Services. The draft lives in the core, and Esc cancels it.
struct CommandsSection: View {
    let model: AppModel

    var body: some View {
        let screen = model.commands.settingsScreen
        if let form = screen.form {
            CommandFormView(model: model, form: form)
        } else {
            CommandsListPage(model: model, screen: screen)
        }
    }
}

/// The list page: title, intro, the file problem, the commands as rows that open their form,
/// or the empty card, and Add command.
private struct CommandsListPage: View {
    let model: AppModel
    let screen: CommandsSettingsScreen

    var body: some View {
        let commands = model.commands
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: screen.title)
            SavingOffLine(settings: model.settings)
            SecondaryLine(text: screen.intro)
            if let problem = screen.fileProblem {
                FileProblemCardView(card: problem, reveal: commands.revealCommandsFile, retry: commands.reloadCommands)
            }
            if let emptyText = screen.emptyCard {
                EmptyListCard(text: emptyText)
            } else if !screen.rows.isEmpty {
                SettingsList {
                    ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        EditorListRow(
                            glyph: .terminal, name: row.name, commandLine: row.commandLine, isEnabled: screen.addEnabled
                        ) {
                            commands.editCommand(row.id)
                        }
                    }
                }
            }
            Button(screen.add) { commands.editCommand(nil) }
                .buttonStyle(.bordered)
                .disabled(!screen.addEnabled)
        }
    }
}

/// The command form: ‹ Commands, the title, name, command and folder with their problems,
/// and the shared bottom bar. Every edit goes to the core's draft.
struct CommandFormView: View {
    let model: AppModel
    let form: CommandFormScreen

    var body: some View {
        let commands = model.commands
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            FormBackButton(title: form.back, back: commands.cancelForm)
            SettingsTitle(text: form.title)
            FormField(label: Strings.ListForm.name, problem: form.problems[.name]) {
                TextField(
                    Strings.ListForm.name, text: draft(form.name) { $0.name = $1 },
                    prompt: Text(Strings.CommandForm.namePlaceholder)
                )
                .onSubmit(commands.saveForm)
            }
            FormField(label: Strings.ListForm.command, problem: form.problems[.command]) {
                TextField(
                    Strings.ListForm.command, text: draft(form.command) { $0.command = $1 },
                    prompt: Text(Strings.CommandForm.commandPlaceholder)
                )
                .font(.system(size: HUDStyle.Settings.labelSize).monospaced())
                .onSubmit(commands.saveForm)
            }
            FormField(label: Strings.ListForm.folder, problem: form.problems[.cwd]) {
                FolderRow(path: form.cwd, chooseTitle: Strings.ListForm.choose) { model.chooseCommandFolder() }
            }
            Hairline()
            FormBottomBar(
                bar: form.bar, saveProblem: form.saveProblem, saveEnabled: form.saveEnabled, remove: form.remove,
                actions: FormBarActions(
                    askRemove: commands.askRemove, cancel: commands.cancelForm, save: commands.saveForm,
                    dismissBar: commands.dismissBar, discard: commands.discardForm,
                    confirmRemove: commands.confirmRemove))
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: HUDStyle.Settings.labelSize))
    }

    /// A text binding to one field of the core's draft.
    private func draft(
        _ value: String, _ write: @escaping (inout CommandDraft, String) -> Void
    ) -> Binding<String> {
        Binding(get: { value }, set: { text in model.commands.updateDraft { write(&$0, text) } })
    }
}
