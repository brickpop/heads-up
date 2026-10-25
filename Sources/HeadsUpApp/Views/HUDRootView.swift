import HeadsUpCore
import SwiftUI

/// The whole HUD, as the panel hosts it: the header, the body and the footer in the frame.
///
/// The body holds the settings-file notice and the suggestions, when there are any, and
/// is empty otherwise, so the HUD collapses to its header and footer. The panel follows
/// this view's height and keeps its top edge where it is.
struct HUDRootView: View {
    let model: AppModel

    var body: some View {
        let hud = model.hud
        let showsSuggestions = !hud.suggestions.isEmpty
        let notice = model.settingsNotice
        HUDFrameView {
            HUDHeader(hud: hud, activity: model.tabActivity)
                .overlay(alignment: .bottom) { Hairline() }
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(AccessibilityOrder.header)
        } content: {
            VStack(spacing: 0) {
                if let notice {
                    SettingsNoticeBar(model: model, text: notice)
                }
                if showsSuggestions {
                    SuggestionList(hud: hud)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(AccessibilityOrder.body)
        } footer: {
            HUDFooter(left: hud.footerLeft, toastID: hud.toastID)
                // With no body, the header's line is the only one.
                .overlay(alignment: .top) {
                    if notice != nil || showsSuggestions { Hairline() }
                }
                .accessibilityElement(children: .contain)
                .accessibilitySortPriority(AccessibilityOrder.footer)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.HUD.accessibilityLabel)
    }
}

/// VoiceOver reads the HUD top to bottom: the tabs and prompt, the body, then the footer.
/// A higher priority is read first.
private enum AccessibilityOrder {
    static let header: Double = 3
    static let body: Double = 2
    static let footer: Double = 1
}

#if DEBUG
    struct HUDRootViewPreviews: PreviewProvider {
        static var previews: some View {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                Group {
                    hud { _ in }.previewDisplayName("Collapsed")
                    hud { $0.hud.setInput("go") }.previewDisplayName("Free text")
                    hud { $0.hud.setInput("/") }.previewDisplayName("Slash")
                    hud { $0.hud.setInput("/xyz") }.previewDisplayName("No match")
                    hud { $0.hud.toast("Focus started · 25 min") }.previewDisplayName("Toast")
                    hud { $0.hud.selectTab(.services) }.previewDisplayName("Other tab")
                    hud(settingsFileProblem: .newerVersion(URL(fileURLWithPath: "/tmp/settings.json"))) { _ in }
                        .previewDisplayName("Settings notice")
                }
                .preferredColorScheme(scheme)
            }
        }

        private static func hud(
            settingsFileProblem: SettingsFileProblem? = nil, _ setUp: (AppModel) -> Void
        ) -> some View {
            let model = AppModel.preview(settingsFileProblem: settingsFileProblem)
            setUp(model)
            return HUDRootView(model: model)
                .frame(width: HUDLayout.maxWidth)
                .padding(40)
        }
    }
#endif
