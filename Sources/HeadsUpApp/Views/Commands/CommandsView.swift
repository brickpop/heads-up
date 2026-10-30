import HeadsUpCore
import SwiftUI

/// The Commands tab: "Command shortcuts" with the terminal picker, then the commands, the
/// file problem, or the empty state. A click on a row opens the command in the terminal.
/// It scrolls past 480 pt, and keeps the row ↑ ↓ select in view.
struct CommandsView: View {
    let model: AppModel

    private let contentHeight = State<CGFloat>(initialValue: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                CommandsContent(model: model, screen: model.commands.screen)
                    .padding(HUDStyle.Services.padding)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight.wrappedValue = $0
                    }
            }
            .frame(height: min(contentHeight.wrappedValue, HUDStyle.Services.maxHeight))
            // A key move scrolls the selected row into view; a click is on a row already there.
            .onChange(of: model.commands.keyboardMoves) {
                guard let id = model.commands.selection else { return }
                withAnimation(reduceMotion ? nil : HUDStyle.Motion.standard) { proxy.scrollTo(id) }
            }
        }
    }
}

private struct CommandsContent: View {
    let model: AppModel
    let screen: CommandsScreen

    /// The focused row, while one has the keyboard focus.
    @FocusState private var focusedRow: Int?

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
                // One Tab stop, on the selected row; ↑ ↓ move it (AppModel.moveCommandSelection).
                ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                    CommandRowView(
                        model: model, row: row, isTabStop: row.isSelected || index == focusedRow, focus: $focusedRow,
                        index: index
                    )
                    .id(row.id)  // the target of the scroll to the selection
                }
            }
        }
        // After ↑ ↓: VoiceOver hears the newly selected row, and a row that had the keyboard
        // focus hands it on. A click needs neither: the clicked row has both already.
        .onChange(of: commands.keyboardMoves) {
            guard let index = screen.rows.firstIndex(where: \.isSelected) else { return }
            if focusedRow != nil { focusedRow = index }
            AccessibilityNotification.Announcement(screen.rows[index].accessibilityLabel).post()
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
/// run shows under the row, with the button that fixes it. The selected row has the gray --sel
/// fill, and is the list's one Tab stop.
private struct CommandRowView: View {
    let model: AppModel
    let row: CommandsScreen.Row
    let isTabStop: Bool
    let focus: FocusState<Int?>.Binding
    let index: Int

    private let isHovered = State(initialValue: false)

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
                    // ⌘↩ runs the selected row, as ⏎ runs the selected suggestion. VoiceOver
                    // users reach the row directly; the keycap is for the eye.
                    if row.isSelected {
                        Keycap(key: Strings.Commands.runKey)
                            .accessibilityHidden(true)
                    }
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
                .background(fill, in: RoundedRectangle(cornerRadius: HUDStyle.Services.rowCornerRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(CardFocus(isTabStop: isTabStop, focus: focus, index: index))
            .onHover { isHovered.wrappedValue = $0 }
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
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
                .announcing(problem.text)
            }
        }
    }

    /// The selected row has the gray selection, Raycast-style, not accent; another under the
    /// pointer gets the lighter raised fill, so only one ever looks selected.
    private var fill: Color {
        if row.isSelected { return HUDStyle.Colors.selection }
        return isHovered.wrappedValue ? HUDStyle.Colors.raise : Color.clear
    }

    /// A click on the row: it becomes the selection, then runs, or opens its form when it
    /// can't run (the same as ⌘↩).
    private func activate() {
        model.activateCommand(row.id)
    }

    private func fix(_ kind: CommandsScreen.FixKind) {
        switch kind {
        case .openAutomation: model.openAutomationSettings()
        case .openGeneral: model.openTerminalSetting()
        case .tryAgain: model.runCommand(row.id)
        }
    }
}
