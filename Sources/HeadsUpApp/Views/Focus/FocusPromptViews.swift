import HeadsUpCore
import SwiftUI

/// "Time for a break": the break options, the length, and Keep working (only after a
/// session that ended by itself), Snooze and Start break. VoiceOver announces it once.
struct BreakPromptView: View {
    let focus: FocusStore
    let screen: FocusScreen.BreakPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: 2) {
                FocusLabel(text: screen.label)
                FocusTitle(text: screen.title)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: HUDStyle.Focus.optionMinWidth), spacing: HUDStyle.Focus.cardGap)],
                spacing: HUDStyle.Focus.cardGap
            ) {
                ForEach(screen.options, id: \.id) { option in
                    FocusCard(
                        isSelected: option.isSelected, isTabStop: false, select: { focus.selectActivity(option.id) }
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
                labels: screen.options.map(\.accessibilityLabel), selected: screen.options.firstIndex { $0.isSelected }
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
                if let keepWorking = screen.keepWorking {
                    Button(keepWorking, action: focus.keepWorking)
                        .buttonStyle(.borderless)
                        .help(screen.keepWorkingHelp)
                }
                Spacer()
                SnoozeButton(title: screen.snooze, focus: focus)
                Button(screen.startBreak, action: focus.startBreak)
                    .buttonStyle(.borderedProminent)
            }
        }
        .announcing(screen.title)
    }
}

/// "Ready to get back to it?": today's stats, and Done for now, Snooze and Start focus.
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
            HStack {
                Button(screen.doneForNow, action: focus.doneForNow)
                    .buttonStyle(.borderless)
                Spacer()
                SnoozeButton(title: screen.snooze, focus: focus)
                Button {
                    focus.start()
                } label: {
                    Label(screen.start, systemImage: Glyph.play.symbolName)
                }
                .buttonStyle(.borderedProminent)
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
            Button(screen.showNow, action: focus.showNow)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Snooze N min, with the bell.
private struct SnoozeButton: View {
    let title: String
    let focus: FocusStore

    var body: some View {
        Button(action: focus.snooze) {
            Label(title, systemImage: Symbols.snooze)
        }
        .buttonStyle(.bordered)
    }
}
