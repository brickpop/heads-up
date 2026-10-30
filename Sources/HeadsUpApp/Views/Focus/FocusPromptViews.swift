import HeadsUpCore
import SwiftUI

/// "Time for a break": the break options, then Stop for now and Snooze, Start break, and the
/// Length group under Start.
/// VoiceOver announces it once.
struct BreakPromptView: View {
    let focus: FocusStore
    let screen: FocusScreen.BreakPrompt

    /// The focused break option, while one is.
    @FocusState private var focusedCard: Int?

    var body: some View {
        let selected = screen.options.firstIndex { $0.isSelected }
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: 2) {
                FocusLabel(text: screen.label)
                FocusTitle(text: screen.title)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: HUDStyle.Focus.optionMinWidth), spacing: HUDStyle.Focus.cardGap)],
                spacing: HUDStyle.Focus.cardGap
            ) {
                ForEach(Array(screen.options.enumerated()), id: \.element.id) { index, option in
                    FocusCard(
                        isSelected: option.isSelected, isTabStop: index == (selected ?? 0) || index == focusedCard,
                        focus: $focusedCard, index: index, select: { focus.selectActivity(option.id) }
                    ) {
                        HStack(spacing: HUDStyle.Focus.cardGap) {
                            Image(systemName: option.glyph.symbolName)
                                .frame(width: HUDStyle.Focus.optionChipSize, height: HUDStyle.Focus.optionChipSize)
                                .background(
                                    HUDStyle.Colors.chip,
                                    in: RoundedRectangle(cornerRadius: HUDStyle.Suggestions.chipCornerRadius)
                                )
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(option.label)
                                    .font(.system(size: HUDStyle.Settings.labelSize, weight: .medium))
                                    .lineLimit(1)
                                Text(option.length)
                                    .font(.system(size: HUDStyle.Focus.cardHintSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .cardGroupKeys(
                labels: screen.options.map(\.accessibilityLabel), selected: selected, focus: $focusedCard,
                keyboardMoves: focus.cardMoves
            ) {
                focus.selectActivity(screen.options[$0].id)
            }
            // Row 1: Stop for now and Snooze on the left, Start on the right. Row 2: Length under
            // Start, right-aligned with it. Tab order: Stop for now, Snooze, Start, Length.
            HStack(alignment: .top, spacing: 0) {
                PromptLeftActions(done: screen.done, snooze: screen.snooze, focus: focus)
                Spacer(minLength: HUDStyle.Focus.gap)
                VStack(alignment: .trailing, spacing: HUDStyle.CardButton.spacing) {
                    Button(action: focus.startBreak) {
                        FocusPrimaryLabel(title: screen.startBreak)
                    }
                    .buttonStyle(.hud(.primary))
                    .accessibilityHint(Strings.Focus.primaryShortcutHint)
                    // A click selects the length; it doesn't start the break.
                    SegmentGroupView(
                        symbol: Symbols.breakLength, label: Strings.Focus.length,
                        accessibilityLabel: Strings.Focus.lengthGroupAccessibility,
                        segments: screen.lengths.map {
                            SegmentGroupView.Segment(
                                id: $0.minutes, title: $0.title, accessibilityLabel: $0.accessibilityLabel,
                                isSelected: $0.isSelected)
                        }, select: focus.setBreakLength, act: focus.setBreakLength)
                }
            }
        }
        .announcing(screen.title)
    }
}

/// "Ready to get back to it?": today's stats, the focus length cards with the last focus's
/// length selected, and Stop for now, Snooze and Start focus of the selected length.
struct BackPromptView: View {
    let focus: FocusStore
    let screen: FocusScreen.BackPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: 2) {
                FocusLabel(text: screen.label)
                FocusTitle(text: screen.title)
                Text(screen.today)
                    .font(.system(size: HUDStyle.Focus.statsSize))
                    .foregroundStyle(.secondary)
            }
            FocusLengthCards(lengths: screen.lengths, cardMoves: focus.cardMoves, select: focus.setNextFocusLength)
            // The break prompt's row 1; the length cards above take the place of its Length row.
            HStack(spacing: 0) {
                PromptLeftActions(done: screen.done, snooze: screen.snooze, focus: focus)
                Spacer(minLength: HUDStyle.Focus.gap)
                Button {
                    focus.start()
                } label: {
                    FocusPrimaryLabel(title: screen.start, glyph: .play)
                }
                .buttonStyle(.hud(.primary))
                .accessibilityHint(Strings.Focus.primaryShortcutHint)
            }
        }
        .announcing(screen.title)
    }
}

/// Snoozed: when the prompt comes back, and Show now.
struct SnoozedView: View {
    let focus: FocusStore
    let screen: FocusScreen.Snoozed

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: 2) {
                FocusLabel(text: screen.label)
                FocusTitle(text: screen.title, size: HUDStyle.Focus.snoozedTitleSize)
            }
            Button(action: focus.showNow) {
                FocusPrimaryLabel(title: screen.showNow, onAccent: false)
            }
            .buttonStyle(.hud(.secondary))
            .accessibilityHint(Strings.Focus.primaryShortcutHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The left of both prompts' first row: Stop for now (secondary: it ends the loop), then the
/// snooze group, two separate controls 8 pt apart. A click on a snooze length snoozes at once;
/// the selected length, where esc snoozes, starts at Settings' and moves with ⌥⇧← ⌥⇧→ or ← → in
/// the group.
private struct PromptLeftActions: View {
    let done: String
    let snooze: FocusScreen.SnoozeGroup
    let focus: FocusStore

    var body: some View {
        HStack(spacing: HUDStyle.CardButton.spacing) {
            Button(done, action: focus.doneForNow)
                .buttonStyle(.hud(.secondary))
                .help(Strings.Focus.doneHelp)
            SegmentGroupView(
                symbol: Symbols.snooze, label: snooze.label,
                segments: snooze.choices.map {
                    SegmentGroupView.Segment(
                        id: $0.minutes, title: $0.title, accessibilityLabel: $0.accessibilityLabel,
                        isSelected: $0.isSelected)
                }, keyboardMoves: focus.snoozeMoves, select: focus.selectSnooze
            ) { focus.snooze(minutes: $0) }
        }
    }
}
