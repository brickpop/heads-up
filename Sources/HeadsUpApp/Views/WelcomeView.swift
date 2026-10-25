import AppKit
import HeadsUpCore
import SwiftUI

/// The first-run welcome in the Chat body (UX part 1, §3): how to open HeadsUp, then two
/// steps, setting up a model and Open at Login. When the wake shortcut didn't register,
/// it says why and offers the recorder before the steps.
struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        let hud = model.hud
        let shortcut = model.settings.settings.general.shortcut
        VStack(spacing: HUDStyle.Welcome.spacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: HUDStyle.Welcome.iconSize, height: HUDStyle.Welcome.iconSize)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(Strings.Welcome.title)
                    .font(.system(size: HUDStyle.Welcome.titleSize, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(model.welcomeShortcutLine)
                    .foregroundStyle(.secondary)
                if let problem = model.welcomeProblemLine {
                    // Why the shortcut doesn't work, then the recorder to choose another.
                    HotkeyNotes(model: model, problem: problem)
                    ShortcutRecorder(hud: hud, shortcut: shortcut)
                }
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
                WelcomeStep(number: 1, text: Strings.Welcome.addModel) {
                    Button(Strings.Welcome.setUpModel, action: model.welcomeSetUpModel)
                        .buttonStyle(.borderedProminent)
                }
                WelcomeStep(number: 2, text: Strings.Welcome.openAtLogin) {
                    Toggle(
                        Strings.Welcome.openAtLogin,
                        isOn: Binding(get: { model.openAtLogin.isOn }, set: { model.setOpenAtLogin($0) })
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
                if let error = model.openAtLoginError {
                    ProblemNote(text: error)
                }
                if let note = model.openAtLoginNote {
                    OpenAtLoginNoteView(model: model, note: note)
                }
                Text(Strings.Welcome.changeLater)
                    .font(.system(size: HUDStyle.Settings.helpSize))
                    .foregroundStyle(.secondary)
                    .padding(.leading, HUDStyle.Welcome.stepIconSize + HUDStyle.Settings.sectionSpacing)
            }
            // The steps keep a readable width in the middle of the 760 pt HUD.
            .frame(maxWidth: HUDStyle.Welcome.stepsMaxWidth)
        }
        .font(.system(size: HUDStyle.Settings.labelSize))
        .frame(maxWidth: .infinity)
        .padding(HUDStyle.Welcome.padding)
        .onAppear { model.refreshOpenAtLogin() }
    }
}

/// One numbered step: its number, what it does, and its control on the right.
private struct WelcomeStep<Control: View>: View {
    let number: Int
    let text: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: HUDStyle.Settings.sectionSpacing) {
            Image(systemName: Symbols.step(number))
                .font(.system(size: HUDStyle.Welcome.stepIconSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
            Spacer(minLength: HUDStyle.Settings.sectionSpacing)
            control
        }
    }
}
