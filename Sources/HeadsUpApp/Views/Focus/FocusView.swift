import HeadsUpCore
import SwiftUI

/// The Focus tab. It redraws once a second while the HUD is open, from the core's display model
/// for that moment, and shows the view for the phase: idle, running, a prompt, or snoozed.
struct FocusView: View {
    let focus: FocusStore
    /// The HUD is open: only then does the timer tick.
    let isOpen: Bool

    var body: some View {
        EverySecond(isRunning: isOpen) { now in
            FocusScreenView(focus: focus, screen: focus.screen(at: now))
        }
        .padding(.top, HUDStyle.Focus.topPadding)
        .padding(.horizontal, HUDStyle.Focus.sidePadding)
        .padding(.bottom, HUDStyle.Focus.bottomPadding)
    }
}

private struct FocusScreenView: View {
    let focus: FocusStore
    let screen: FocusScreen

    var body: some View {
        switch screen {
        case .idle(let idle): FocusIdleView(focus: focus, screen: idle)
        case .running(let running): FocusRunningView(focus: focus, screen: running)
        case .breakPrompt(let prompt): BreakPromptView(focus: focus, screen: prompt)
        case .backPrompt(let prompt): BackPromptView(focus: focus, screen: prompt)
        case .snoozed(let snoozed): SnoozedView(focus: focus, screen: snoozed)
        }
    }
}

/// The small label above a timer or a title: 11 pt semibold, tertiary.
struct FocusLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Focus.labelSize, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// The big timer: 64 pt Light with tabular digits, read by VoiceOver as the time left.
struct FocusTimer: View {
    let text: String
    var accessibilityText: String?

    var body: some View {
        Text(text)
            .font(.system(size: HUDStyle.Focus.timerSize, weight: .light).monospacedDigit())
            .tracking(HUDStyle.Focus.timerTracking)
            .accessibilityLabel(accessibilityText ?? text)
    }
}

/// A prompt's title, 28 pt semibold, or 22 pt for the snoozed one.
struct FocusTitle: View {
    let text: String
    var size = HUDStyle.Focus.titleSize

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A selectable card: an accent border and the gray fill when selected. Used for the focus
/// lengths, the break options and the Caffeine durations. It reads as a button with a
/// "selected" state. In a group that is one Tab stop (`cardGroupKeys`), the card itself takes
/// no keyboard focus.
struct FocusCard<Content: View>: View {
    let isSelected: Bool
    var isTabStop = true
    let select: @MainActor () -> Void
    @ViewBuilder var content: Content

    @State private var isHovered = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: select) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HUDStyle.Focus.cardPadding)
                .background(fill, in: shape)
                .overlay(
                    shape.strokeBorder(
                        isSelected ? Color.accentColor : HUDStyle.Colors.line,
                        lineWidth: isSelected
                            ? HUDStyle.Focus.selectedBorder
                            : HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .modifier(OutOfTabOrder(isActive: !isTabStop))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : HUDStyle.Motion.standard, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        isSelected ? HUDStyle.Colors.selection : (isHovered ? HUDStyle.Colors.raise : Color.clear)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Focus.cardCornerRadius)
    }
}

/// Takes a card out of the Tab order when its group is the Tab stop. Any other card keeps the
/// system's rule: a Tab stop only with Keyboard navigation on.
private struct OutOfTabOrder: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive { content.focusable(false) } else { content }
    }
}

extension View {
    /// Makes a group of cards one Tab stop, like a macOS radio group (UX part 2, §21): with the
    /// group focused, ← and ↑ select the previous card and → and ↓ the next, stopping at the ends.
    /// The cards inside pass `isTabStop: false`. `labels` are the cards' VoiceOver labels, which
    /// say which one is selected.
    func cardGroupKeys(labels: [String], selected: Int?, select: @escaping @MainActor (Int) -> Void) -> some View {
        modifier(CardGroupKeys(labels: labels, selected: selected, select: select))
    }
}

private struct CardGroupKeys: ViewModifier {
    let labels: [String]
    let selected: Int?
    let select: @MainActor (Int) -> Void

    /// An arrow press changed the selection, so VoiceOver should hear the new card. A click
    /// doesn't need it: VoiceOver reads the card it pressed.
    @State private var announceNext = false

    func body(content: Content) -> some View {
        content
            .focusable()
            .onKeyPress(keys: [.leftArrow, .upArrow, .rightArrow, .downArrow]) { press in
                guard !labels.isEmpty else { return .ignored }
                let step = press.key == .leftArrow || press.key == .upArrow ? -1 : 1
                let current = selected ?? (step > 0 ? -1 : labels.count)
                let next = min(max(current + step, 0), labels.count - 1)
                if next != selected {
                    announceNext = true
                    select(next)
                }
                return .handled
            }
            .onChange(of: selected) { _, new in
                guard announceNext, let new, labels.indices.contains(new) else { return }
                announceNext = false
                AccessibilityNotification.Announcement(labels[new]).post()
            }
            .accessibilityElement(children: .contain)
    }
}
