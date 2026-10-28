import HeadsUpCore
import SwiftUI

/// A bar at the top of the HUD body for a problem the user should know about: a warning
/// icon, a semibold line, optionally a second line of detail, and its buttons. It is 36 pt
/// with one line and grows with two. VoiceOver announces all of its text when it appears.
struct NoticeBar<Actions: View>: View {
    let text: String
    var detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: HUDStyle.Notice.gap) {
            Image(systemName: Symbols.warning)
                .foregroundStyle(HUDStyle.Colors.warn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: HUDStyle.Notice.fontSize, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: HUDStyle.Settings.helpSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, HUDStyle.Notice.padding)
        .padding(.vertical, detail == nil ? 0 : HUDStyle.Notice.detailPadding)
        .frame(minHeight: HUDStyle.Notice.height)
        .background(HUDStyle.Colors.raise, in: RoundedRectangle(cornerRadius: HUDStyle.Notice.cornerRadius))
        .padding(HUDStyle.Notice.margin)
        .accessibilityElement(children: .contain)
        .announcing(announcement)
    }

    private var announcement: String {
        detail.map { "\(text) \($0)" } ?? text
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
