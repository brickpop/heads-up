import SwiftUI

/// One key drawn as a bordered keycap, e.g. "⏎" or "⌘1–6", in hints and on the selected row.
/// Its `tone` follows the fill under it: plain, white on an accent fill, black on amber.
struct Keycap: View {
    let key: String
    var tone = Tone.plain

    enum Tone {
        /// Secondary text and the `--line-strong` hairline.
        case plain
        /// On an accent-filled (primary) button.
        case onAccent
        /// On an amber-filled (break) button.
        case onAmber
    }

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(key)
            .font(.system(size: HUDStyle.Keycap.fontSize, weight: .medium))
            .foregroundStyle(text)
            .padding(.horizontal, HUDStyle.Keycap.padding)
            .frame(minWidth: HUDStyle.Keycap.height, minHeight: HUDStyle.Keycap.height)
            .overlay(
                RoundedRectangle(cornerRadius: HUDStyle.Keycap.cornerRadius)
                    .strokeBorder(line, lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
    }

    private var text: AnyShapeStyle {
        switch tone {
        case .plain: AnyShapeStyle(.secondary)
        case .onAccent: AnyShapeStyle(HUDStyle.Colors.keycapOnAccent)
        case .onAmber: AnyShapeStyle(HUDStyle.Colors.onAmber(contrast))
        }
    }

    private var line: Color {
        switch tone {
        case .plain: HUDStyle.Colors.line
        case .onAccent: HUDStyle.Colors.keycapOnAccentLine
        case .onAmber: HUDStyle.Colors.keycapOnAmberLine
        }
    }
}
