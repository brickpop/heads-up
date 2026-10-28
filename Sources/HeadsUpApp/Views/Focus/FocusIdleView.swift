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
            HStack(spacing: HUDStyle.Focus.cardGap) {
                ForEach(screen.lengths, id: \.minutes) { card in
                    FocusCard(
                        isSelected: card.isSelected, isTabStop: false, select: { focus.setFocusLength(card.minutes) }
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
                labels: screen.lengths.map(\.accessibilityLabel), selected: screen.lengths.firstIndex { $0.isSelected }
            ) {
                focus.setFocusLength(screen.lengths[$0].minutes)
            }
            HStack {
                Text(screen.breaksOffer)
                    .font(.system(size: HUDStyle.Focus.cardHintSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: HUDStyle.Focus.gap)
                Button {
                    focus.start()
                } label: {
                    Label(screen.start, systemImage: Glyph.play.symbolName)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
