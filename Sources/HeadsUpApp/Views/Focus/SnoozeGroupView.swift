import HeadsUpCore
import SwiftUI

/// "Snooze │ 2m 5m 10m", on both Focus prompts (Yuki, ux-card-buttons › Snooze group): one
/// 28 pt container in the secondary button look. "Snooze" is a label; each segment snoozes for
/// its length at once. The default length (Settings › Focus › Snooze length) has the selected
/// item's fill of a segmented control, `--seg-on`, and nothing in the group uses the accent.
///
/// The group is one Tab stop: Tab lands on the default segment, ← → move the focus and stop at
/// the ends without snoozing, Space snoozes for the focused one.
struct SnoozeGroupView: View {
    let group: FocusScreen.SnoozeGroup
    let snooze: @MainActor (Int) -> Void

    /// The focused segment, while one is.
    @FocusState private var focused: Int?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let standard = group.choices.firstIndex { $0.isDefault } ?? 0
        let line = HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale)
        HStack(spacing: 0) {
            HStack(spacing: HUDStyle.Snooze.iconGap) {
                Image(systemName: Symbols.snooze)
                    .font(.system(size: HUDStyle.Snooze.iconSize, weight: .medium))
                Text(group.label)
                    .font(.system(size: HUDStyle.Snooze.fontSize, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Snooze.labelPadding)
            // The container says "Snooze"; each segment says it again with its length.
            .accessibilityHidden(true)
            Rectangle()
                .fill(HUDStyle.Colors.line)
                .frame(width: line, height: HUDStyle.Snooze.dividerHeight)
                .padding(.trailing, HUDStyle.Snooze.inset)
                .accessibilityHidden(true)
            ForEach(Array(group.choices.enumerated()), id: \.element.minutes) { index, choice in
                Button(choice.title) { snooze(choice.minutes) }
                    .buttonStyle(SnoozeSegmentStyle(isDefault: choice.isDefault))
                    .modifier(
                        CardFocus(isTabStop: index == (focused ?? standard), focus: $focused, index: index)
                    )
                    .accessibilityLabel(choice.accessibilityLabel)
                    .accessibilityValue(choice.isDefault ? Strings.Focus.snoozeDefault : "")
            }
        }
        .padding(.trailing, HUDStyle.Snooze.inset)
        .frame(height: HUDStyle.Snooze.height)
        .background(HUDStyle.Colors.raise, in: container)
        .overlay(container.strokeBorder(HUDStyle.Colors.line, lineWidth: line))
        .fixedSize()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let current = focused else { return .ignored }
            let step = press.key == .leftArrow ? -1 : 1
            focused = min(max(current + step, 0), group.choices.count - 1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label)
    }

    private var container: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Snooze.cornerRadius)
    }
}

/// A snooze segment: 24 pt tall, radius 6, `--raise2` under the pointer and `pressed` while
/// pressed. The default one rests on `--seg-on`, a segmented control's selected item, with a
/// semibold title and no accent: accent is kept for what ⌘↩ starts. Under the pointer and
/// pressed, `.primary` at 6 % and 12 % goes on top of it.
private struct SnoozeSegmentStyle: ButtonStyle {
    let isDefault: Bool

    func makeBody(configuration: Configuration) -> some View {
        SnoozeSegment(configuration: configuration, isDefault: isDefault)
    }
}

/// A segment's body. It is a view, not part of the style, so it can keep whether the pointer is
/// over it.
private struct SnoozeSegment: View {
    let configuration: ButtonStyleConfiguration
    let isDefault: Bool

    private let isHovered = State(initialValue: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(.system(size: HUDStyle.Snooze.fontSize, weight: isDefault ? .semibold : .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, HUDStyle.Snooze.segmentPadding)
            .frame(height: HUDStyle.Snooze.segmentHeight)
            .background { background }
            .contentShape(shape)
            .contentShape(.focusEffect, shape)
            .onHover { isHovered.wrappedValue = $0 }
            // The hover fill fades in; the pressed fill shows at once.
            .animation(
                reduceMotion || configuration.isPressed ? nil : HUDStyle.Motion.standard, value: isHovered.wrappedValue)
    }

    @ViewBuilder private var background: some View {
        if isDefault {
            shape.fill(HUDStyle.Colors.segmentOn)
                // The native soft shadow, in light mode only.
                .shadow(
                    color: .black.opacity(colorScheme == .light ? HUDStyle.Snooze.defaultShadowOpacity : 0),
                    radius: HUDStyle.Snooze.defaultShadowRadius, y: HUDStyle.Snooze.defaultShadowY
                )
                .overlay(shape.fill(Color.primary.opacity(defaultShade)))
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(HUDStyle.Colors.line, lineWidth: 1)
                    }
                }
        } else {
            shape.fill(fill)
        }
    }

    /// `.primary` over the default's fill: pressed, then hovered, else none.
    private var defaultShade: Double {
        if configuration.isPressed { return HUDStyle.Snooze.defaultPressed }
        return isHovered.wrappedValue ? HUDStyle.Snooze.defaultHover : 0
    }

    private var fill: Color {
        if configuration.isPressed { return HUDStyle.Colors.pressed }
        return isHovered.wrappedValue ? HUDStyle.Colors.raise2 : Color.clear
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Snooze.segmentCornerRadius)
    }
}
