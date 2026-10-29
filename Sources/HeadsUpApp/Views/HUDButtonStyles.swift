import SwiftUI

/// The ghost button of the visual language: transparent, secondary text, the `--raise2` fill
/// while the pointer is over it, and a stronger one while it is pressed. The chat toolbar's
/// Pinned · N uses it.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HUDButton(configuration: configuration, hasBorder: false)
    }
}

/// The outline button of the visual language: a ghost button with a hairline border. The chat
/// toolbar's New and Stop use it, and Pin while off.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HUDButton(configuration: configuration, hasBorder: true)
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    /// Transparent, with the hover fill.
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    /// Transparent, with a hairline border and the hover fill.
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

/// A ghost or outline button's body. It is a view, not part of the style, so it can keep
/// whether the pointer is over it.
private struct HUDButton: View {
    let configuration: ButtonStyleConfiguration
    let hasBorder: Bool

    private let isHovered = State(initialValue: false)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        configuration.label
            .font(.system(size: HUDStyle.Footer.fontSize))
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Outline.padding)
            .frame(height: HUDStyle.Outline.height)
            .background(fill, in: shape)
            .overlay {
                if hasBorder {
                    shape.strokeBorder(
                        HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
                }
            }
            .opacity(isEnabled ? 1 : HUDStyle.Chat.unarmedOpacity)
            .contentShape(shape)
            .onHover { isHovered.wrappedValue = $0 }
    }

    /// Pressed, then hovered. A disabled button doesn't light up under the pointer.
    private var fill: Color {
        if configuration.isPressed { return HUDStyle.Colors.pressed }
        return isEnabled && isHovered.wrappedValue ? HUDStyle.Colors.raise2 : Color.clear
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Outline.cornerRadius)
    }
}
