import SwiftUI

/// One key drawn as a bordered keycap, e.g. "⏎" or "⌘1–6", in hints and on the selected row.
/// `onAccent` draws it in white, for a keycap on an accent-filled button.
struct Keycap: View {
    let key: String
    var onAccent = false

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(key)
            .font(.system(size: HUDStyle.Keycap.fontSize, weight: .medium))
            .foregroundStyle(onAccent ? AnyShapeStyle(HUDStyle.Colors.keycapOnAccent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, HUDStyle.Keycap.padding)
            .frame(minWidth: HUDStyle.Keycap.height, minHeight: HUDStyle.Keycap.height)
            .overlay(
                RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius)
                    .strokeBorder(
                        onAccent ? HUDStyle.Colors.keycapOnAccentLine : HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
    }
}
