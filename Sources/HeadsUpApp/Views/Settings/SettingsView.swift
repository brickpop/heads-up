import HeadsUpCore
import SwiftUI

/// The Settings tab: the sub-nav on the left, the chosen section on the right. Its height
/// follows the section, between 380 and 480 pt; past that the section scrolls.
struct SettingsView: View {
    let model: AppModel

    @State private var contentHeight = HUDStyle.Settings.minHeight

    var body: some View {
        HStack(spacing: 0) {
            SettingsNav(hud: model.hud)
            VerticalHairline()
            ScrollView {
                SettingsPane(model: model, section: model.hud.settingsSection)
                    .padding(.top, HUDStyle.Settings.paneTopPadding)
                    .padding(.horizontal, HUDStyle.Settings.paneSidePadding)
                    .padding(.bottom, HUDStyle.Settings.paneBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        contentHeight = $0
                    }
            }
        }
        .frame(height: min(max(contentHeight, HUDStyle.Settings.minHeight), HUDStyle.Settings.maxHeight))
    }
}

/// The sub-nav: one row per section, in groups split by a hairline.
private struct SettingsNav: View {
    let hud: HUDStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Hairline().padding(.vertical, HUDStyle.Settings.navGroupGap)
                }
                ForEach(group, id: \.self) { section in
                    SettingsNavRow(section: section, isSelected: hud.settingsSection == section) {
                        hud.selectSettingsSection(section)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(HUDStyle.Settings.navPadding)
        .frame(width: HUDStyle.Settings.navWidth)
        // With a row focused (Keyboard navigation on), ↑ and ↓ move between sections.
        .onKeyPress(.upArrow) {
            hud.moveSettingsSection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            hud.moveSettingsSection(1)
            return .handled
        }
    }
}

private struct SettingsNavRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let select: @MainActor () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: HUDStyle.Tabs.gap) {
                Image(systemName: section.glyph.symbolName)
                    .frame(width: HUDStyle.Settings.navIconWidth)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.system(size: HUDStyle.Settings.labelSize))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
            .frame(height: HUDStyle.Settings.navRowHeight)
            .background(
                isSelected ? HUDStyle.Colors.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: HUDStyle.Settings.navRowCornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The chosen section. Sections that later slices build show their title only.
private struct SettingsPane: View {
    let model: AppModel
    let section: SettingsSection

    var body: some View {
        switch section {
        case .general:
            GeneralSection(model: model)
        case .focus:
            FocusSection(model: model)
        case .models, .tools, .services, .commands:
            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                SettingsTitle(text: section.title)
                SavingOffLine(settings: model.settings)
            }
        }
    }
}

/// A section's title: 18 pt semibold.
struct SettingsTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Settings.titleSize, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// "Changes aren't saved right now. See General.", under the title of every section but
/// General, while the settings file must not be written.
struct SavingOffLine: View {
    let settings: SettingsStore

    var body: some View {
        if !settings.savingEnabled {
            Text(Strings.SettingsFile.savingOffLine)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(.secondary)
        }
    }
}

/// A bordered list of settings rows, with a hairline between rows.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .overlay(
            RoundedRectangle(cornerRadius: HUDStyle.Settings.listCornerRadius)
                .strokeBorder(
                    HUDStyle.Colors.line,
                    lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
    }
}

/// One settings row: the label and its help on the left, the control on the right, and
/// notes under it (a problem, a link to System Settings).
struct SettingsRow<Control: View, Notes: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: Control
    @ViewBuilder var notes: Notes

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Footer.keyGap) {
            HStack(spacing: HUDStyle.Settings.sectionSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: HUDStyle.Settings.labelSize))
                    if let help {
                        Text(help)
                            .font(.system(size: HUDStyle.Settings.helpSize))
                            .foregroundStyle(.secondary)
                    }
                }
                // VoiceOver reads the label and its help together, then the control, which
                // carries its own label.
                .accessibilityElement(children: .combine)
                Spacer(minLength: HUDStyle.Settings.sectionSpacing)
                control
            }
            notes
        }
        .padding(.horizontal, HUDStyle.Settings.rowHorizontalPadding)
        .padding(.vertical, HUDStyle.Settings.rowVerticalPadding)
    }
}

extension SettingsRow where Notes == EmptyView {
    init(title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: title, help: help, control: control, notes: { EmptyView() })
    }
}

/// A note under a settings row, in red, for something that needs fixing.
struct ProblemNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Settings.helpSize))
            .foregroundStyle(HUDStyle.Colors.alert)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A vertical separator line, as thin as `Hairline`.
struct VerticalHairline: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HUDStyle.Colors.line
            .frame(width: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            .accessibilityHidden(true)
    }
}
