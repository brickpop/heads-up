import HeadsUpCore
import SwiftUI

/// Settings → Tools: one row per local tool, with its icon, what it does, and a segmented
/// control of the permissions it allows (Add reminders only has Ask and Off).
struct ToolsSection: View {
    let model: AppModel

    var body: some View {
        let screen = model.settings.toolsScreen
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: screen.title)
            SavingOffLine(settings: model.settings)
            SecondaryLine(text: screen.intro)
            SettingsList {
                ForEach(Array(screen.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Hairline() }
                    ToolSettingRow(row: row) { model.settings.setToolPermission(row.id, $0) }
                }
            }
        }
    }
}

/// A tool's row: the 30 pt icon chip, the label in semibold, its description, the mono
/// function and any help, and the permission control on the right.
private struct ToolSettingRow: View {
    let row: ToolsSettingsScreen.Row
    let set: @MainActor (ToolPermission) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HUDStyle.Settings.sectionSpacing) {
            Image(systemName: row.glyph.symbolName)
                .frame(width: HUDStyle.FocusSettings.chipHeight, height: HUDStyle.FocusSettings.chipHeight)
                .background(
                    HUDStyle.Colors.chip, in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                Text(row.description)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    Text(row.fn)
                        .font(.system(size: HUDStyle.Settings.helpSize).monospaced())
                        .foregroundStyle(.tertiary)
                    if let help = row.help {
                        Text(help)
                            .font(.system(size: HUDStyle.Settings.helpSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: HUDStyle.Settings.sectionSpacing)
            Picker(row.label, selection: Binding(get: { row.selected }, set: { set($0) })) {
                ForEach(row.choices, id: \.permission) { choice in
                    Text(choice.title).tag(choice.permission)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
        .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
    }
}
