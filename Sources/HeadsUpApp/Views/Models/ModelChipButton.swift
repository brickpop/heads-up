import HeadsUpCore
import SwiftUI

/// The model chip in the Chat tab: a 28 pt pill with the active model's name, or "No model",
/// and a chevron. It opens and closes the model menu, and fills while the menu is open.
struct ModelChipButton: View {
    let chip: ModelChip
    let toggle: @MainActor () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: HUDStyle.Footer.keyGap) {
                Text(chip.title)
                    .lineLimit(1)
                Image(systemName: Symbols.chevronDown)
                    .font(.system(size: HUDStyle.ModelChip.chevronSize, weight: .semibold))
            }
            .font(.system(size: HUDStyle.Footer.fontSize, weight: .semibold))
            .foregroundStyle(chip.isPlaceholder ? Color.secondary : Color.primary)
            .padding(.horizontal, HUDStyle.ModelChip.padding)
            .frame(height: HUDStyle.ModelChip.height)
            .background(chip.isOpen ? HUDStyle.Colors.raise2 : Color.clear, in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    HUDStyle.Colors.line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(chip.accessibilityLabel)
        .accessibilityAddTraits(chip.isOpen ? [.isSelected] : [])
    }
}
