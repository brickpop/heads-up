import HeadsUpCore
import SwiftUI

/// The settings-file problem in Settings → General (Yuki's copy, place 2): what happened and
/// what the user can do. "Use Defaults and Save…" asks first, in the card itself, and keeps
/// the old file under the name the question gives.
struct SettingsFileCard: View {
    let settings: SettingsStore
    let problem: SettingsFileProblem

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HUDStyle.Notice.gap) {
            Image(systemName: Symbols.warning)
                .foregroundStyle(HUDStyle.Colors.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.SettingsFile.title(problem))
                        .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                    InlineMarkdownText(Strings.SettingsFile.text(problem))
                        .font(.system(size: HUDStyle.Settings.helpSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let question = settings.useDefaultsConfirmation {
                    confirmation(question)
                } else {
                    buttons
                }
            }
            Spacer(minLength: 0)
            if problem.canBeDismissed {
                Button(action: settings.dismissFileProblem) {
                    Image(systemName: Symbols.close)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Strings.SettingsFile.dismiss)
            }
        }
        .padding(HUDStyle.Settings.cardPadding)
        .overlay(
            RoundedRectangle(cornerRadius: HUDStyle.Settings.listCornerRadius)
                .strokeBorder(
                    HUDStyle.Colors.line,
                    lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: HUDStyle.Notice.gap) {
            switch problem {
            case .keptAside, .defaultsChosen:
                showInFinder
            case .unreadable, .newerVersion:
                showInFinder
                Button(Strings.SettingsFile.useDefaultsAndSave, action: settings.beginUseDefaults)
                    .buttonStyle(.borderless)
            case .saveFailed(_, let keptAs):
                Button(Strings.SettingsFile.tryAgain, action: settings.retrySave)
                    .buttonStyle(.bordered)
                if keptAs != nil {
                    showInFinder
                }
            }
        }
        .controlSize(.small)
    }

    private var showInFinder: some View {
        Button(Strings.SettingsFile.showInFinder, action: settings.revealSettingsFile)
            .buttonStyle(.bordered)
    }

    /// "Start over with default settings? Your current file is kept as …" Cancel · Use Defaults,
    /// with no default button, so Enter can't answer it by accident.
    private func confirmation(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: HUDStyle.Notice.gap) {
            InlineMarkdownText(question)
                .font(.system(size: HUDStyle.Settings.helpSize))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: HUDStyle.Notice.gap) {
                Button(Strings.SettingsFile.cancel, action: settings.cancelUseDefaults)
                    .buttonStyle(.borderless)
                Button(Strings.SettingsFile.useDefaults, action: settings.useDefaultsAndSave)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}
