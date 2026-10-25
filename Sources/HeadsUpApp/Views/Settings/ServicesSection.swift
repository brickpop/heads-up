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
                EmptyListCard(text: emptyText)
            } else if !screen.rows.isEmpty {
                SettingsList {
                    ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        EditorListRow(
                            glyph: .server, name: row.name, commandLine: row.commandLine, isEnabled: screen.addEnabled
                        ) {
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
