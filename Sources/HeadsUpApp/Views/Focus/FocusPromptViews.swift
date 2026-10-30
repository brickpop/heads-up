import HeadsUpCore
import SwiftUI

/// "Time for a break": the break options, the length, and Done, Snooze and Start break.
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
            HStack(spacing: HUDStyle.Focus.cardGap) {
                Text(Strings.Focus.length)
                    .font(.system(size: HUDStyle.Settings.labelSize))
                    .foregroundStyle(.secondary)
                Picker(
                    Strings.Focus.length,
                    selection: Binding(get: { screen.selectedLength }, set: { focus.setBreakLength($0) })
                ) {
                    ForEach(screen.lengths, id: \.minutes) { choice in
                        Text(choice.title).tag(choice.minutes)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                DoneButton(title: screen.done, focus: focus)
                Spacer()
                SnoozeGroupView(group: screen.snooze) { focus.snooze(minutes: $0) }
                Button(action: focus.startBreak) {
                    FocusPrimaryLabel(title: screen.startBreak)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(Strings.Focus.primaryShortcutHint)
            }
        }
        .announcing(screen.title)
    }
}

/// "Ready to get back to it?": today's stats, the focus length cards with the last focus's
/// length selected, and Done, Snooze and Start focus of the selected length.
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
            HStack {
                DoneButton(title: screen.done, focus: focus)
                Spacer()
                SnoozeGroupView(group: screen.snooze) { focus.snooze(minutes: $0) }
                Button {
                    focus.start()
                } label: {
                    FocusPrimaryLabel(title: screen.start, glyph: .play)
                }
                .buttonStyle(.borderedProminent)
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
            .buttonStyle(.bordered)
            .accessibilityHint(Strings.Focus.primaryShortcutHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Done, on both prompts: ends the loop. Bordered, so it reads as a button, not as text.
private struct DoneButton: View {
    let title: String
    let focus: FocusStore

    var body: some View {
        Button(title, action: focus.doneForNow)
            .buttonStyle(.bordered)
            .help(Strings.Focus.doneHelp)
    }
}
