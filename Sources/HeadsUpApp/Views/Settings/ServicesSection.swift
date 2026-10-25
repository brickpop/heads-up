import HeadsUpCore
import SwiftUI

/// Settings → Services: the list of services, or the form of the one being edited (UX part 1,
/// §1, list-and-form). The form's draft lives in the core, so it survives a tab change or a
/// closed HUD, and Esc cancels it.
struct ServicesSection: View {
    let model: AppModel

    var body: some View {
        let screen = model.services.settingsScreen
        if let form = screen.form {
            ServiceFormView(model: model, form: form)
        } else {
            ServicesListPage(model: model, screen: screen)
        }
    }
}

/// The list page: title, intro, the file problem, the services as rows that open their form,
/// or the empty card, and Add service.
private struct ServicesListPage: View {
    let model: AppModel
    let screen: ServicesSettingsScreen

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let services = model.services
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: screen.title)
            SavingOffLine(settings: model.settings)
            if let cantEdit = screen.cantEditLine {
                SecondaryLine(text: cantEdit)
            }
            SecondaryLine(text: screen.intro)
            // Stays after the isolation notice in the tab is dismissed.
            if let isolation = screen.isolationLine {
                SecondaryLine(text: isolation)
            }
            if let problem = screen.fileProblem {
                FileProblemCardView(card: problem, reveal: services.revealServicesFile, retry: services.reloadServices)
            }
            if let emptyText = screen.emptyCard {
                Text(emptyText)
                    .font(.system(size: HUDStyle.Settings.labelSize))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HUDStyle.Settings.cardPadding)
                    .overlay(
                        RoundedRectangle(cornerRadius: HUDStyle.Settings.listCornerRadius)
                            .strokeBorder(
                                HUDStyle.Colors.line,
                                lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
                    )
            } else if !screen.rows.isEmpty {
                SettingsList {
                    ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        ServiceListRow(name: row.name, commandLine: row.commandLine, isEnabled: screen.addEnabled) {
                            services.editService(row.id)
                        }
                    }
                }
            }
            Button(screen.add) { services.editService(nil) }
                .buttonStyle(.bordered)
                .disabled(!screen.addEnabled)
        }
    }
}

/// A service in the Settings list: chip, name, mono command line, and a chevron. A click or
/// Enter opens its form.
private struct ServiceListRow: View {
    let name: String
    let commandLine: String
    let isEnabled: Bool
    let open: @MainActor () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: HUDStyle.Services.rowGap) {
                Image(systemName: Glyph.server.symbolName)
                    .frame(width: HUDStyle.Suggestions.chipSize, height: HUDStyle.Suggestions.chipSize)
                    .background(
                        HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                    Text(commandLine)
                        .font(.system(size: HUDStyle.Services.metaSize).monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: Symbols.disclosure)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
            .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
            .background(isHovered && isEnabled ? HUDStyle.Colors.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
    }
}

/// A 12 pt secondary line under a section title, with any file names in mono.
private struct SecondaryLine: View {
    let text: String

    var body: some View {
        InlineMarkdownText(text)
            .font(.system(size: HUDStyle.Settings.helpSize))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
