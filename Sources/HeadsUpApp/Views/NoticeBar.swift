import HeadsUpCore
import SwiftUI

/// A 36 pt bar at the top of the HUD body for a problem the user should know about:
/// a warning icon, one line of text and its buttons. The settings-file notice uses it
/// now, the vision notice later. VoiceOver announces the text when the bar appears.
struct NoticeBar<Actions: View>: View {
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: HUDStyle.Notice.gap) {
            Image(systemName: Symbols.warning)
                .foregroundStyle(HUDStyle.Colors.warn)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: HUDStyle.Notice.fontSize, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, HUDStyle.Notice.padding)
        .frame(height: HUDStyle.Notice.height)
        .background(HUDStyle.Colors.raise, in: RoundedRectangle(cornerRadius: HUDStyle.Notice.cornerRadius))
        .padding(HUDStyle.Notice.margin)
        .accessibilityElement(children: .contain)
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

/// The settings-file notice: shown once per launch when settings.json couldn't be read
/// or saved. Open Settings goes to Settings → General, where the details are.
struct SettingsNoticeBar: View {
    let model: AppModel
    let text: String

    var body: some View {
        NoticeBar(text: text) {
            Button(Strings.SettingsNotice.openSettings) {
                model.openSettingsFromNotice()
            }
            .buttonStyle(.bordered)
            Button {
                model.dismissSettingsNotice()
            } label: {
                Image(systemName: Symbols.close)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Strings.SettingsNotice.dismiss)
        }
    }
}
