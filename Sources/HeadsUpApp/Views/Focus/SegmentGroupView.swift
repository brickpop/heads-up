import HeadsUpCore
import SwiftUI

/// A labelled row of segments in the snooze group's look (Yuki, ux-card-buttons › Snooze group):
/// one 28 pt container in the secondary button look, an icon and a label, a hairline, then the
/// segments. The selected one rests on `--seg-on`, a segmented control's selected item, and
/// nothing in the group uses the accent. The break prompts' Snooze (a click snoozes) and Length
/// (a click selects) use it.
///
/// The group is one Tab stop: Tab lands on the selected segment, and ← → select the next one and
/// move the focus with it, stopping at the ends, without acting; Space acts on the focused one.
/// When `keyboardMoves` changes (a key moved the selection from the prompt field), VoiceOver
/// hears the newly selected segment.
struct SegmentGroupView: View {
    let symbol: String
    let label: String
    /// What VoiceOver says for the group, when it differs from `label`.
    var accessibilityLabel: String?
    let segments: [Segment]
    var keyboardMoves = 0
    /// ← → in the group: selects a segment without acting.
    let select: @MainActor (Int) -> Void
    let act: @MainActor (Int) -> Void

    /// One segment: `id` is what `act` gets, its minutes.
    struct Segment {
        let id: Int
        let title: String
        let accessibilityLabel: String
        let isSelected: Bool
    }

    /// The focused segment, while one is.
    @FocusState private var focused: Int?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let selected = segments.firstIndex { $0.isSelected } ?? 0
        let line = HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale)
        HStack(spacing: 0) {
            HStack(spacing: HUDStyle.Snooze.iconGap) {
                Image(systemName: symbol)
                    .font(.system(size: HUDStyle.Snooze.iconSize, weight: .medium))
                Text(label)
                    .font(.system(size: HUDStyle.Snooze.fontSize, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, HUDStyle.Snooze.labelPadding)
            // The container says the label; each segment says it again with its length.
            .accessibilityHidden(true)
            Rectangle()
                .fill(HUDStyle.Colors.line)
                .frame(width: line, height: HUDStyle.Snooze.dividerHeight)
                .padding(.trailing, HUDStyle.Snooze.inset)
                .accessibilityHidden(true)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                Button(segment.title) { act(segment.id) }
                    .buttonStyle(SegmentStyle(isSelected: segment.isSelected))
                    .modifier(
                        CardFocus(isTabStop: index == (focused ?? selected), focus: $focused, index: index)
                    )
                    .accessibilityLabel(segment.accessibilityLabel)
                    .accessibilityAddTraits(segment.isSelected ? [.isSelected] : [])
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
            let next = min(max(current + step, 0), segments.count - 1)
            select(segments[next].id)
            focused = next
            return .handled
        }
        .onChange(of: keyboardMoves) {
            guard let segment = segments.first(where: \.isSelected) else { return }
            AccessibilityNotification.Announcement(segment.accessibilityLabel).post()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? label)
    }

    private var container: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Snooze.cornerRadius)
    }
}

/// A segment: 24 pt tall, radius 6, `--raise2` under the pointer and `pressed` while pressed.
/// The selected one rests on `--seg-on` with a semibold title and no accent: accent is kept for
/// what ⌘↩ starts. Under the pointer and pressed, `.primary` at 6 % and 12 % goes on top of it.
private struct SegmentStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isSelected: isSelected)
    }
}

/// A segment's body. It is a view, not part of the style, so it can keep whether the pointer is
/// over it.
private struct SegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    private let isHovered = State(initialValue: false)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(.system(size: HUDStyle.Snooze.fontSize, weight: isSelected ? .semibold : .medium))
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
        if isSelected {
            shape.fill(HUDStyle.Colors.segmentOn)
                // The native soft shadow, in light mode only.
                .shadow(
                    color: .black.opacity(colorScheme == .light ? HUDStyle.Snooze.defaultShadowOpacity : 0),
                    radius: HUDStyle.Snooze.defaultShadowRadius, y: HUDStyle.Snooze.defaultShadowY
                )
                .overlay(shape.fill(Color.primary.opacity(selectedShade)))
                .overlay {
                    if contrast == .increased {
                        shape.strokeBorder(HUDStyle.Colors.line, lineWidth: 1)
                    }
                }
        } else {
            shape.fill(fill)
        }
    }

    /// `.primary` over the selected fill: pressed, then hovered, else none.
    private var selectedShade: Double {
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
