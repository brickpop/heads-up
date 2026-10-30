import HeadsUpCore
import SwiftUI

/// Settings → Models: the endpoints, quick add, New model, and the add or edit form below them
/// once one of these or a row opens it. When the form closes, the focus goes back to New model.
struct ModelsSection: View {
    let model: AppModel

    @FocusState private var newModelFocused: Bool

    var body: some View {
        let screen = model.endpoints.settingsScreen
        let endpoints = model.endpoints
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: screen.title)
            SavingOffLine(settings: model.settings)
            SecondaryLine(text: screen.intro)
            if let empty = screen.emptyCard {
                EmptyListCard(text: empty)
            }
            if !screen.quickAdd.isEmpty {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    ForEach(screen.quickAdd, id: \.kind) { item in
                        QuickAddButton(item: item) { endpoints.quickAdd(item.kind) }
                    }
                }
            }
            if !screen.rows.isEmpty {
                SettingsList {
                    ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        // The id Settings scrolls to after an add.
                        EndpointRowView(endpoints: endpoints, row: row).id(row.id)
                    }
                }
            }
            // An endpoint was removed, but the Keychain kept its token.
            if let problem = screen.listProblem {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    ProblemNote(text: problem.text)
                    Button(problem.tryAgain) { endpoints.retryTokenDelete() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if let newModel = screen.newModel {
                Button {
                    endpoints.newEndpoint()
                } label: {
                    Label(newModel, systemImage: Glyph.plus.symbolName)
                }
                .buttonStyle(.bordered)
                .focused($newModelFocused)
            }
            if screen.showsForm {
                EndpointFormView(model: model, form: screen.form)
            }
        }
        // Cancel, esc or an add closed the form: a keyboard user isn't left with nothing focused.
        .onChange(of: screen.showsForm) { wasShowing, shows in
            if wasShowing && !shows { newModelFocused = true }
        }
    }
}

/// A quick-add button: OpenAI, Ollama, LM Studio or Other. A green dot shows when that
/// local server already answers on this Mac.
private struct QuickAddButton: View {
    let item: ModelsSettingsScreen.QuickAdd
    let add: @MainActor () -> Void

    var body: some View {
        Button(action: add) {
            HStack(spacing: HUDStyle.Footer.keyGap) {
                if item.running {
                    Circle()
                        .fill(HUDStyle.Colors.running)
                        .frame(width: HUDStyle.Services.warningDotSize, height: HUDStyle.Services.warningDotSize)
                        .accessibilityHidden(true)
                }
                Text(item.title)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(item.runningHelp ?? "")
        .accessibilityHint(item.runningHelp ?? "")
    }
}

/// One endpoint: the default radio, the name with its tag, the mono URL and model id, the
/// masked token, and ×. A click on the row edits it.
private struct EndpointRowView: View {
    let endpoints: EndpointService
    let row: ModelsSettingsScreen.Row

    var body: some View {
        if let bar = row.removeBar {
            RemoveEndpointBar(endpoints: endpoints, bar: bar)
                .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
                .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
        } else {
            details
        }
    }

    private var details: some View {
        HStack(spacing: HUDStyle.Services.rowGap) {
            Button {
                endpoints.setDefault(row.id)
            } label: {
                Image(systemName: row.isDefault ? Symbols.radioOn : Symbols.radioOff)
                    .foregroundStyle(row.isDefault ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(Strings.EndpointForm.setDefault)
            .accessibilityLabel(row.radioLabel)
            .accessibilityValue(row.name)
            .accessibilityAddTraits(row.isDefault ? [.isSelected] : [])

            Button {
                endpoints.editEndpoint(row.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: HUDStyle.Footer.keyGap) {
                        Text(row.name)
                            .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                        TagPill(text: row.tag, help: row.tagHelp)
                        if let local = row.localTag {
                            TagPill(text: local, help: Strings.Models.localTagHelp)
                        }
                    }
                    Text(row.urlLine)
                        .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(row.token)
                        .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                endpoints.removeEndpoint(row.id)
            } label: {
                Image(systemName: Symbols.close)
            }
            .buttonStyle(.borderless)
            .help(row.removeHelp)
            .accessibilityLabel(row.removeHelp)
        }
        .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
        .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
        .background(row.isEditing ? HUDStyle.Colors.selection : Color.clear)
    }
}

/// "Remove GPT-4o? Its token is deleted from the Keychain." in place of the row, with Cancel
/// and a red Remove, no default button, announced when it appears.
private struct RemoveEndpointBar: View {
    let endpoints: EndpointService
    let bar: ModelsSettingsScreen.RemoveBar

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            HStack {
                Text(bar.question)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(bar.cancel) { endpoints.cancelRemoveEndpoint() }
                    .buttonStyle(.bordered)
                Button {
                    endpoints.confirmRemoveEndpoint()
                } label: {
                    Text(bar.remove).foregroundStyle(HUDStyle.Colors.alert)
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .announcing(bar.question)
    }
}
