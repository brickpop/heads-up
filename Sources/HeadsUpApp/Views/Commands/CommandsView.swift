import HeadsUpCore
import SwiftUI

/// The Commands tab: "Command shortcuts" with the terminal picker, then the commands, the
/// file problem, or the empty state. A click on a row opens the command in the terminal.
/// It scrolls past 480 pt.
struct CommandsView: View {
    let model: AppModel

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            CommandsContent(model: model, screen: model.commands.screen)
                .padding(HUDStyle.Services.padding)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
        }
        .frame(height: min(contentHeight, HUDStyle.Services.maxHeight))
    }
}

private struct CommandsContent: View {
    let model: AppModel
    let screen: CommandsScreen

    var body: some View {
        let commands = model.commands
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            HStack(alignment: .firstTextBaseline) {
                FocusLabel(text: screen.label)
                Spacer()
                if let picker = screen.terminalPicker {
                    HStack(spacing: HUDStyle.Footer.keyGap) {
                        Text(picker.label)
                            .font(.system(size: HUDStyle.Footer.fontSize))
                            .foregroundStyle(.secondary)
                        TerminalPickerControl(picker: picker, commands: commands)
                    }
                }
                Button(screen.edit) { model.openCommandsSettings() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, HUDStyle.Services.headerPadding)
            .padding(.vertical, HUDStyle.Footer.keyGap)

            if let problem = screen.fileProblem {
                FileProblemCardView(card: problem, reveal: commands.revealCommandsFile, retry: commands.reloadCommands)
            } else if let empty = screen.empty {
                CommandsEmptyView(empty: empty, add: model.addCommand)
            } else {
                ForEach(screen.rows) { row in
                    CommandRowView(model: model, row: row)
                }
            }
        }
    }
}

/// The installed terminals: a segmented control for up to three, a pop-up menu for more.
/// The same setting as Settings → General.
struct TerminalPickerControl: View {
    let picker: TerminalPicker
    let commands: CommandStore

    var body: some View {
        let control = Picker(
            picker.label, selection: Binding(get: { picker.selectedID }, set: { commands.setTerminal($0) })
        ) {
            ForEach(picker.choices) { choice in
                Text(choice.title).tag(choice.id)
            }
        }
        .labelsHidden()
        .fixedSize()
        switch picker.style {
        case .segmented: control.pickerStyle(.segmented)
        case .menu: control.pickerStyle(.menu)
        }
    }
}

/// No commands yet: a chip, the title and one line, and Add a command….
private struct CommandsEmptyView: View {
    let empty: CommandsScreen.Empty
    let add: @MainActor () -> Void

    var body: some View {
        VStack(spacing: HUDStyle.Settings.sectionSpacing) {
            Image(systemName: Glyph.terminal.symbolName)
                .font(.system(size: HUDStyle.Suggestions.chipIconSize))
                .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                .background(
                    HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                )
                .accessibilityHidden(true)
            Text(empty.title)
                .font(.system(size: HUDStyle.Services.emptyTitleSize, weight: .semibold))
            Text(empty.text)
                .font(.system(size: HUDStyle.Settings.labelSize))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(empty.add, action: add)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(HUDStyle.Welcome.padding)
    }
}

/// One command: the terminal chip, name, mono command and folder, and the pill naming the
/// terminal it opens in. A click runs it. A command that breaks a rule shows why in orange,
/// has Edit… in place of the pill, and a click opens its form instead. A problem from the last
/// run shows under the row, with the button that fixes it.
private struct CommandRowView: View {
    let model: AppModel
    let row: CommandsScreen.Row

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            Button(action: activate) {
                HStack(spacing: HUDStyle.Services.rowGap) {
                    Image(systemName: Glyph.terminal.symbolName)
                        .font(.system(size: HUDStyle.Suggestions.chipIconSize))
                        .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                        .background(
                            HUDStyle.Colors.chip,
                            in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                        )
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: HUDStyle.Footer.keyGap) {
                            Text(row.name)
                                .font(.system(size: HUDStyle.Suggestions.titleSize, weight: .semibold))
                            if let meta = row.meta {
                                Text(meta)
                                    .font(.system(size: HUDStyle.Services.metaSize))
                                    .foregroundStyle(HUDStyle.Colors.warn)
                            }
                        }
                        .lineLimit(1)
                        Text(row.command)
                            .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(row.cwd)
                            .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: HUDStyle.Services.rowGap)
                    switch row.action {
                    case .run:
                        Label(row.terminal, systemImage: Symbols.externalLink)
                            .font(.system(size: HUDStyle.Footer.fontSize, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, HUDStyle.Pill.padding)
                            .frame(height: HUDStyle.Pill.height)
                            .background(HUDStyle.Colors.raise2, in: Capsule())
                    case .edit(let title):
                        Button(title, action: activate)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(HUDStyle.Services.rowPadding)
                .background(
                    isHovered ? HUDStyle.Colors.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: HUDStyle.Services.rowCornerRadius)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.accessibilityValue)
            .accessibilityHint(row.accessibilityHint)

            if let problem = row.problem {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    ProblemNote(text: problem.text)
                    Button(problem.fix.title) { fix(problem.fix.kind) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .padding(.leading, HUDStyle.Services.drawerLeading)
                .onAppear { AccessibilityNotification.Announcement(problem.text).post() }
            }
        }
    }

    /// A click on the row: run it, or open its form when it can't run.
    private func activate() {
        switch row.action {
        case .run: model.runCommand(row.id)
        case .edit: model.editCommand(row.id)
        }
    }

    private func fix(_ kind: CommandsScreen.FixKind) {
        switch kind {
        case .openAutomation: model.openAutomationSettings()
        case .openGeneral: model.openTerminalSetting()
        case .tryAgain: model.runCommand(row.id)
        }
    }
}
