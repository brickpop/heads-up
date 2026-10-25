import HeadsUpCore
import SwiftUI

/// The footer's status pills, visible from any tab: the Focus pill while a focus or break
/// runs, is paused or is snoozed, then the Caffeine pill while it is on. The text changes every
/// second, and only while the HUD shows.
struct StatusPills: View {
    let focus: FocusStore
    let caffeine: CaffeineStore
    /// The HUD is open: only then do the pills tick.
    let isOpen: Bool

    var body: some View {
        EverySecond(isRunning: isOpen) { now in
            HStack(spacing: HUDStyle.Pill.gap) {
                if let text = focus.pill(at: now) {
                    StatusPill(glyph: .timer, text: text)
                }
                if let text = caffeine.pill(at: now) {
                    StatusPill(glyph: .cup, text: text)
                }
            }
        }
    }
}

/// One pill: 22 pt, a glyph and semibold tabular text on the raised fill.
struct StatusPill: View {
    let glyph: Glyph
    let text: String

    var body: some View {
        HStack(spacing: HUDStyle.Pill.iconGap) {
            Image(systemName: glyph.symbolName)
                .accessibilityHidden(true)
            Text(text)
                .monospacedDigit()
        }
        .font(.system(size: HUDStyle.Footer.fontSize, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, HUDStyle.Pill.padding)
        .frame(height: HUDStyle.Pill.height)
        .background(HUDStyle.Colors.raise2, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
