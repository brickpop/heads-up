import HeadsUpCore
import SwiftUI

/// Settings → General: the settings-file card when there is a problem, then Open at Login,
/// the wake shortcut, appearance and the HUD's behaviour switches.
struct GeneralSection: View {
    let model: AppModel

    var body: some View {
        let general = model.settings.settings.general
        VStack(alignment: .leading, spacing: HUDStyle.Settings.sectionSpacing) {
            SettingsTitle(text: Strings.General.title)
            if let problem = model.settings.fileProblem {
                SettingsFileCard(settings: model.settings, problem: problem)
            }
            SettingsList {
                openAtLoginRow
                Hairline()
                WakeShortcutRow(model: model, shortcut: general.shortcut)
                Hairline()
                SettingsRow(title: Strings.General.appearance) {
                    Picker(Strings.General.appearance, selection: binding(\.appearance)) {
                        ForEach(Appearance.allCases, id: \.self) { appearance in
                            Text(Strings.General.appearanceName(appearance)).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                // Hidden with only one terminal installed: there is nothing to choose.
                if let picker = model.commands.terminalSetting {
                    Hairline()
                    SettingsRow(title: picker.label) {
                        TerminalPickerControl(picker: picker, commands: model.commands)
                    }
                }
                Hairline()
                switchRow(Strings.General.menuSeconds, help: Strings.General.menuSecondsHelp, \.menuSeconds)
                Hairline()
                switchRow(Strings.General.clearOnClose, help: Strings.General.clearOnCloseHelp, \.clearOnClose)
                Hairline()
                switchRow(
                    Strings.General.closeOnClickOutside,
                    help: Strings.General.closeOnClickOutsideHelp(shortcut: general.shortcut.displayName),
                    \.closeOnClickOutside)
            }
        }
        .onAppear { model.refreshOpenAtLogin() }
    }

    /// Open at Login, with the note when macOS needs approval or couldn't add HeadsUp.
    private var openAtLoginRow: some View {
        SettingsRow(title: Strings.General.openAtLogin, help: Strings.General.openAtLoginHelp) {
            Toggle(
                Strings.General.openAtLogin,
                isOn: Binding(
                    get: { model.openAtLogin.isOn }, set: { model.setOpenAtLogin($0) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        } notes: {
            if let error = model.openAtLoginError {
                ProblemNote(text: error)
            }
            if let note = model.openAtLoginNote {
                OpenAtLoginNoteView(model: model, note: note)
            }
        }
    }

    private func switchRow(_ title: String, help: String, _ keyPath: WritableKeyPath<General, Bool>) -> some View {
        SettingsRow(title: title, help: help) {
            Toggle(title, isOn: binding(keyPath))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    /// A binding to one General setting; setting it saves.
    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<General, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings.settings.general[keyPath: keyPath] },
            set: { value in model.settings.update { $0.general[keyPath: keyPath] = value } })
    }
}

/// The wake shortcut row: the recorder, Reset when it isn't the default, and the notes for
/// a shortcut that didn't register or that the recorder refused.
private struct WakeShortcutRow: View {
    let model: AppModel
    let shortcut: Shortcut

    var body: some View {
        let hud = model.hud
        SettingsRow(title: Strings.General.wakeShortcut) {
            HStack(spacing: HUDStyle.Footer.keyGap) {
                if hud.canResetShortcut {
                    Button(Strings.Recorder.reset(Shortcut.wakeDefault.displayName), action: hud.resetShortcut)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                ShortcutRecorder(hud: hud, shortcut: shortcut)
            }
        } notes: {
            HotkeyNotes(model: model, problem: Strings.Hotkey.problem(model.hud.hotkey, shortcut: shortcut))
        }
    }
}

/// What is wrong with the wake shortcut, in red, with the button that helps: the recorder's
/// refusal, or the lasting note when the shortcut didn't register (UX addendum 4).
struct HotkeyNotes: View {
    let model: AppModel
    /// Why the shortcut didn't register, from the core, or nil while it works.
    let problem: String?

    var body: some View {
        let hud = model.hud
        if let refusal = hud.recorderProblem {
            ProblemNote(text: refusal)
        } else if let problem {
            HStack(spacing: HUDStyle.Footer.keyGap) {
                ProblemNote(text: problem)
                switch hud.hotkey {
                case .reservedBySystem:
                    Button(Strings.General.openKeyboardSettings, action: model.openKeyboardShortcutsSettings)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                case .failed:
                    Button(Strings.General.tryAgain, action: hud.retryHotkey)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                case .ok, .taken:
                    EmptyView()
                }
            }
        }
    }
}

/// The note under Open at Login, in secondary text, with the button that helps if there is one.
struct OpenAtLoginNoteView: View {
    let model: AppModel
    let note: OpenAtLoginNote

    var body: some View {
        HStack(spacing: HUDStyle.Footer.keyGap) {
            Text(Strings.General.loginNote(note))
                .font(.system(size: HUDStyle.Settings.helpSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch note {
            case .needsApproval:
                Button(Strings.General.openLoginItems, action: model.openLoginItemsSettings)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            case .moveToApplications:
                Button(Strings.General.showInFinder, action: model.showAppInFinder)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            case .couldNotAdd:
                EmptyView()
            }
        }
    }
}
