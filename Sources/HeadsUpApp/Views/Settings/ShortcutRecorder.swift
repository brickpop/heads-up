import HeadsUpCore
import SwiftUI

/// The wake shortcut as keycaps in a button-like field. A click, or Space, starts recording:
/// the field turns accent and reads "Type a shortcut…", and the next key press is recorded
/// by the app's key monitor. Esc or the × cancels.
struct ShortcutRecorder: View {
    let hud: HUDStore
    let shortcut: Shortcut

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if hud.recording {
                HStack(spacing: HUDStyle.Footer.keyGap) {
                    Text(Strings.Recorder.prompt)
                        .font(.system(size: HUDStyle.Settings.helpSize))
                        .foregroundStyle(.secondary)
                    Button(action: hud.cancelRecording) {
                        Image(systemName: Symbols.close)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(Strings.Recorder.cancel)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Strings.Recorder.accessibilityLabel)
                .accessibilityValue(Strings.Recorder.prompt)
            } else {
                Button(action: hud.startRecording) {
                    HStack(spacing: 2) {
                        ForEach(Array(shortcut.keycaps.enumerated()), id: \.offset) { _, key in
                            Keycap(key: key)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Strings.Recorder.accessibilityLabel)
                .accessibilityValue(shortcut.displayName)
            }
        }
        .padding(.horizontal, HUDStyle.Recorder.padding)
        .frame(height: HUDStyle.Recorder.height)
        .overlay(
            RoundedRectangle(cornerRadius: HUDStyle.Recorder.cornerRadius)
                .strokeBorder(
                    hud.recording ? Color.accentColor : HUDStyle.Colors.line,
                    lineWidth: hud.recording
                        ? HUDStyle.Recorder.recordingBorder
                        : HUDStyle.lineWidth(contrast: contrast, displayScale: displayScale))
        )
    }
}
