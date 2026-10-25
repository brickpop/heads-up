import HeadsUpCore
import SwiftUI

/// A data file HeadsUp can't use (services.json, later commands.json): what happened, in the
/// core's words with file names in mono, and Show in Finder, with Try Again when a reload can help.
struct FileProblemCardView: View {
    let card: FileProblemCard
    let reveal: @MainActor () -> Void
    let retry: @MainActor () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HUDStyle.Notice.gap) {
            Image(systemName: Symbols.warning)
                .foregroundStyle(HUDStyle.Colors.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .font(.system(size: HUDStyle.Settings.labelSize, weight: .semibold))
                    InlineMarkdownText(card.text)
                        .font(.system(size: HUDStyle.Settings.helpSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: HUDStyle.Notice.gap) {
                    Button(card.showInFinder, action: reveal)
                        .buttonStyle(.bordered)
                    if let tryAgain = card.tryAgain {
                        Button(tryAgain, action: retry)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
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
}
