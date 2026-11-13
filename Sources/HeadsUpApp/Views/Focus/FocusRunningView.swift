import HeadsUpCore
import SwiftUI

/// A focus or a break that runs or is paused: the countdown, its subtitle, the progress bar and
/// the buttons, [Pause] [Stop for now] … [Take a break] in a focus and [Pause] … [Skip break] in a break.
struct FocusRunningView: View {
    let focus: FocusStore
    let screen: FocusScreen.Running

    var body: some View {
        VStack(alignment: .leading, spacing: HUDStyle.Focus.gap) {
            VStack(alignment: .leading, spacing: 0) {
                FocusLabel(text: screen.label)
                FocusTimer(text: screen.timer, accessibilityText: screen.timerAccessibility)
                Text(screen.subtitle)
                    .font(.system(size: HUDStyle.Focus.statsSize))
                    .foregroundStyle(.secondary)
            }
            FocusProgressBar(progress: screen.progress, label: screen.label)
            HStack(spacing: HUDStyle.CardButton.spacing) {
                Button(action: focus.togglePause) {
                    Label(screen.pauseTitle, systemImage: screen.pauseGlyph.symbolName)
                }
                .buttonStyle(.hud(.secondary))
                if let stop = screen.stop { button(stop) }
                Spacer()
                button(screen.end)
            }
        }
    }

    private func button(_ action: FocusScreen.RunAction) -> some View {
        Button {
            focus.run(action)
        } label: {
            Label(action.title, systemImage: action.glyph.symbolName)
        }
        .buttonStyle(.hud(Self.kind(action)))
    }

    /// Red for Stop for now, which loses the session; the warn colour for the break buttons.
    private static func kind(_ action: FocusScreen.RunAction) -> HUDButtonStyle.Kind {
        switch action {
        case .stopForNow: .destructive
        case .takeBreak, .skipBreak: .breakSecondary
        }
    }
}

/// A 6 pt bar, accent on the track, that fills as time passes. It moves linearly over each
/// second, or in steps with Reduce Motion. VoiceOver reads it as a percentage.
struct FocusProgressBar: View {
    let progress: Double
    let label: String

    /// What the bar draws: `progress`, reached with an animation only when it grows.
    private let shown = State<Double>(initialValue: 0)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(HUDStyle.Colors.track)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * shown.wrappedValue)
            }
        }
        .frame(height: HUDStyle.Focus.progressHeight)
        // A new run starts the bar at its new value at once: it never rewinds on screen.
        .onChange(of: progress, initial: true) { old, new in
            if new > old && !reduceMotion {
                withAnimation(.linear(duration: 1)) { shown.wrappedValue = new }
            } else {
                shown.wrappedValue = new
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}
