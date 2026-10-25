import SwiftUI

/// The outline button of the visual language: transparent with a hairline border, secondary
/// text, and the raised fill while pressed. The chat toolbar's New uses it, and Pin while off.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: HUDStyle.Footer.fontSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Outline.padding)
            .frame(height: HUDStyle.Outline.height)
            .background(
                configuration.isPressed ? HUDStyle.Colors.raise : Color.clear,
                in: RoundedRectangle(cornerRadius: HUDStyle.Outline.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HUDStyle.Outline.cornerRadius)
                    .strokeBorder(
                        HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
            )
            .opacity(isEnabled ? 1 : HUDStyle.Chat.unarmedOpacity)
            .contentShape(RoundedRectangle(cornerRadius: HUDStyle.Outline.cornerRadius))
    }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    /// Transparent, with a hairline border.
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}
