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
/// "selected" state. In a group that is one Tab stop (`cardGroupKeys`), only the selected card
/// takes keyboard focus, through `focus` at its `index`.
struct FocusCard<Content: View>: View {
    let isSelected: Bool
    var isTabStop = true
    var focus: FocusState<Int?>.Binding?
    var index = 0
    let select: @MainActor () -> Void
    @ViewBuilder var content: Content

    private let isHovered = State(initialValue: false)
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
        .modifier(CardFocus(isTabStop: isTabStop, focus: focus, index: index))
        .onHover { isHovered.wrappedValue = $0 }
        .animation(reduceMotion ? nil : HUDStyle.Motion.standard, value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        isSelected ? HUDStyle.Colors.selection : (isHovered.wrappedValue ? HUDStyle.Colors.raise : Color.clear)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HUDStyle.Focus.cardCornerRadius)
    }
}

/// A card's keyboard focus, or a Commands row's.
///
/// In a group (`focus` set), the Tab-stop card is focusable whatever the system's Keyboard
/// navigation setting, as a radio group is: a plain Button is a Tab stop only with that setting
/// on, which would leave the group's arrow keys out of reach. Space still presses it. The
/// others are out of the Tab order, and the card is bound to the group's focus so the focus can
/// follow the selection.
///
/// Outside a group, a card keeps the system's rule, unless `isTabStop` takes it out.
struct CardFocus: ViewModifier {
    let isTabStop: Bool
    let focus: FocusState<Int?>.Binding?
    let index: Int

    func body(content: Content) -> some View {
        if let focus {
            content
                .focusable(isTabStop, interactions: .activate)
                .focused(focus, equals: index)
        } else if !isTabStop {
            content.focusable(false)
        } else {
            content
        }
    }
}

extension View {
    /// Makes a group of cards one Tab stop, like a macOS radio group (UX part 2, §21): Tab lands
    /// on the selected card, and with it focused ← and ↑ select the previous card and → and ↓ the
    /// next, stopping at the ends, with the focus following. The cards pass `isTabStop` true for
    /// the selected one, and for the focused one until the focus has moved on (so it never
    /// falls elsewhere for a frame), and `focus` with their index. `labels` are the cards'
    /// VoiceOver labels, which say which one is selected. `keyboardMoves` counts the moves made
    /// with ⌥← ⌥→ from the prompt field, which VoiceOver hears too.
    func cardGroupKeys(
        labels: [String], selected: Int?, focus: FocusState<Int?>.Binding, keyboardMoves: Int,
        select: @escaping @MainActor (Int) -> Void
    ) -> some View {
        modifier(
            CardGroupKeys(
                labels: labels, selected: selected, focus: focus, keyboardMoves: keyboardMoves, select: select))
    }
}

private struct CardGroupKeys: ViewModifier {
    let labels: [String]
    let selected: Int?
    let focus: FocusState<Int?>.Binding
    let keyboardMoves: Int
    let select: @MainActor (Int) -> Void

    /// An arrow press changed the selection: the focus moves to the new card, and VoiceOver
    /// should hear it. A click doesn't need either: the clicked card has them already.
    private let arrowMove = State(initialValue: false)

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.leftArrow, .upArrow, .rightArrow, .downArrow]) { press in
                guard !labels.isEmpty else { return .ignored }
                let step = press.key == .leftArrow || press.key == .upArrow ? -1 : 1
                let current = selected ?? (step > 0 ? -1 : labels.count)
                let next = min(max(current + step, 0), labels.count - 1)
                if next != selected {
                    arrowMove.wrappedValue = true
                    select(next)
                }
                return .handled
            }
            // Runs once the new card is the Tab stop, so it can take the focus.
            .onChange(of: selected) { _, new in
                guard arrowMove.wrappedValue, let new, labels.indices.contains(new) else { return }
                arrowMove.wrappedValue = false
                focus.wrappedValue = new
                announce(new)
            }
            .onChange(of: keyboardMoves) {
                if let selected { announce(selected) }
            }
            .accessibilityElement(children: .contain)
    }

    private func announce(_ index: Int) {
        guard labels.indices.contains(index) else { return }
        AccessibilityNotification.Announcement(labels[index]).post()
    }
}

/// The label of the Focus tab's primary button: its title, then the ⌘↩ keycap that runs it
/// from the prompt field. The keycap is white on an accent-filled (`.borderedProminent`)
/// button; pass `onAccent: false` on a bordered one. The button itself adds
/// `.accessibilityHint(Strings.Focus.primaryShortcutHint)`.
struct FocusPrimaryLabel: View {
    let title: String
    var glyph: Glyph?
    var onAccent = true

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            if let glyph {
                Label(title, systemImage: glyph.symbolName)
            } else {
                Text(title)
            }
            // VoiceOver users reach the button directly; the keycap is for the eye.
            Keycap(key: Strings.Focus.primaryShortcut, onAccent: onAccent)
                .accessibilityHidden(true)
        }
    }
}
