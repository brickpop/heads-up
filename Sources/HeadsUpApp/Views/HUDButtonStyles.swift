import SwiftUI

/// The ghost button of the visual language: transparent, secondary text, the `--raise2` fill
/// while the pointer is over it, and a stronger one while it is pressed. The chat toolbar's
/// Pinned · N uses it.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostOutlineButtonBody(configuration: configuration, hasBorder: false)
    }
}

/// The outline button of the visual language: a ghost button with a hairline border. The chat
/// toolbar's New and Stop use it, and Pin while off.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostOutlineButtonBody(configuration: configuration, hasBorder: true)
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
private struct GhostOutlineButtonBody: View {
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
            .contentShape(.focusEffect, shape)
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

/// The HUD's buttons in the selection cards' materials (Visual language › Buttons): 28 pt tall,
/// radius 8, with a resting fill so they never look like an unselected card. Settings forms,
/// menus and alerts keep native buttons.
struct HUDButtonStyle: ButtonStyle {
    enum Kind: Equatable {
        /// The accent fill and a white title: at most one per view.
        case primary
        /// `--raise` and a hairline.
        case secondary
        /// As secondary, with a red title and icon. Never a red fill.
        case destructive
        /// A 28 pt square with the icon only; `isOn` for a toggle, which then shows `--raise2`.
        case iconOnly(isOn: Bool = false)
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    /// A card-style HUD button of `kind`.
    static func hud(_ kind: HUDButtonStyle.Kind) -> HUDButtonStyle { HUDButtonStyle(kind: kind) }
}

/// A card-style button's body. It is a view, not part of the style, so it can keep whether the
/// pointer is over it. It acts on mouse-up inside it, as every SwiftUI button does.
private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: HUDButtonStyle.Kind

    private let isHovered = State(initialValue: false)
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(foreground)
            .frame(width: isIconOnly ? HUDStyle.CardButton.height : nil, height: HUDStyle.CardButton.height)
            .background { background }
            .overlay {
                if kind != .primary {
                    shape.strokeBorder(
                        HUDStyle.Colors.line,
                        lineWidth: HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
                }
            }
            .opacity(isEnabled ? 1 : HUDStyle.Chat.unarmedOpacity)
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { isHovered.wrappedValue = $0 }
            // The hover fill fades in; the pressed fill shows at once.
            .animation(
                reduceMotion || configuration.isPressed ? nil : HUDStyle.Motion.standard,
                value: isHovered.wrappedValue)
    }

    @ViewBuilder private var label: some View {
        if isIconOnly {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: HUDStyle.CardButton.iconOnlySize))
        } else {
            configuration.label
                .labelStyle(CardButtonLabelStyle())
                .font(.system(size: HUDStyle.CardButton.fontSize, weight: kind == .primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, HUDStyle.CardButton.padding)
        }
    }

    /// The accent with black laid over it for a primary button; the gray fills for the others.
    @ViewBuilder private var background: some View {
        if kind == .primary {
            shape.fill(Color.accentColor)
                .overlay(shape.fill(Color.black.opacity(primaryShade)))
        } else {
            shape.fill(fill)
        }
    }

    private var isPressed: Bool { isEnabled && configuration.isPressed }
    private var isHoveredAndEnabled: Bool { isEnabled && isHovered.wrappedValue }

    private var isIconOnly: Bool {
        if case .iconOnly = kind { return true }
        return false
    }

    private var foreground: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Color.white)
        case .secondary: AnyShapeStyle(.primary)
        case .destructive: AnyShapeStyle(HUDStyle.Colors.alert)
        case .iconOnly(let isOn): isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        }
    }

    private var primaryShade: Double {
        if isPressed { return HUDStyle.CardButton.primaryPressed }
        return isHoveredAndEnabled ? HUDStyle.CardButton.primaryHover : 0
    }

    /// Pressed, then hovered, then at rest (`--raise`, or `--raise2` for a toggle that is on).
    private var fill: Color {
        if isPressed { return HUDStyle.Colors.pressed }
        if isHoveredAndEnabled || kind == .iconOnly(isOn: true) { return HUDStyle.Colors.raise2 }
        return HUDStyle.Colors.raise
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.CardButton.cornerRadius)
    }
}

/// A card-style button's icon and title: the icon at 12 pt medium, 6 pt before the title.
private struct CardButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: HUDStyle.CardButton.gap) {
            configuration.icon
                .font(.system(size: HUDStyle.CardButton.iconSize, weight: .medium))
            configuration.title
        }
    }
}
