import HeadsUpCore
import SwiftUI

/// Idle: the selected length as a big timer, today's stats, the three length cards, the
/// breaks the prompt will offer, and Start focus.
struct FocusIdleView: View {
    let focus: FocusStore
    let screen: FocusScreen.Idle

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    FocusLabel(text: screen.label)
                    FocusTimer(text: screen.timer)
                }
                Spacer(minLength: HUDStyle.Focus.gap)
                Text(screen.today)
                    .font(.system(size: HUDStyle.Focus.statsSize))
                    .foregroundStyle(.secondary)
            }
            FocusLengthCards(lengths: screen.lengths, cardMoves: focus.cardMoves, select: focus.setFocusLength)
            HStack {
                Text(screen.breaksOffer)
                    .font(.system(size: HUDStyle.Focus.cardHintSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    }
}

/// The focus length cards, on idle and on the back prompt: one Tab stop, ← → and ⌥← ⌥→ pick
/// a length (`cardGroupKeys`). `select` gets the picked length in minutes.
struct FocusLengthCards: View {
    let lengths: [FocusScreen.LengthCard]
    let cardMoves: Int
    let select: @MainActor (Int) -> Void

    /// The focused length card, while one is.
    @FocusState private var focusedCard: Int?

    var body: some View {
        let selected = lengths.firstIndex { $0.isSelected }
        HStack(spacing: HUDStyle.Focus.cardGap) {
            ForEach(Array(lengths.enumerated()), id: \.element.minutes) { index, card in
                FocusCard(
                    isSelected: card.isSelected, isTabStop: index == (selected ?? 0) || index == focusedCard,
                    focus: $focusedCard, index: index, select: { select(card.minutes) }
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.system(size: HUDStyle.Focus.cardNumberSize, weight: .semibold))
                        Text(card.hint)
                            .font(.system(size: HUDStyle.Focus.cardHintSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .cardGroupKeys(
            labels: lengths.map(\.accessibilityLabel), selected: selected, focus: $focusedCard,
            keyboardMoves: cardMoves
        ) {
            select(lengths[$0].minutes)
        }
    }
}
