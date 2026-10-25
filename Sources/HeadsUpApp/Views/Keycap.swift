import SwiftUI

/// One key drawn as a bordered keycap, e.g. "⏎" or "⌘1–6", in hints and on the selected row.
struct Keycap: View {
    let key: String

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(key)
            .font(.system(size: HUDStyle.Keycap.fontSize, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Keycap.padding)
            .frame(minWidth: HUDStyle.Keycap.height, minHeight: HUDStyle.Keycap.height)
            .overlay(
                RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius)
                    .strokeBorder(
                        HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
    }
}
