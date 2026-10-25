import HeadsUpCore
import SwiftUI
import UniformTypeIdentifiers

/// The whole HUD, as the panel hosts it: the header, the body and the footer in the frame.
///
/// The body holds the settings-file notice, then the suggestions while there are any, or
/// else the tab's own body: Focus, Settings, or the welcome on Chat at first run. With none of
/// these the body is empty and the HUD collapses to its header and footer. The panel
/// follows this view's height and keeps its top edge where it is.
struct HUDRootView: View {
    let model: AppModel

    /// What the HUD would do with the items dragged over it, while they are.
    @State private var dropZone: DropZone?

    var body: some View {
        let hud = model.hud
        let notice = model.settingsNotice
        let hudBody = model.body
        HUDFrameView {
            HUDHeader(
                hud: hud, activity: model.tabActivity, chip: model.modelChip, attachments: model.chat.attachments,
                removeAttachment: { model.chat.removeAttachment($0) }, buttons: model.chatButtons,
                attach: { model.pickImages() }
            )
            .overlay(alignment: .bottom) { Hairline() }
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(AccessibilityOrder.header)
        } content: {
            VStack(spacing: 0) {
                // One notice at a time: the settings file's wins, since it shows once per launch.
                if let notice {
                    SettingsNoticeBar(model: model, text: notice)
                } else if let attachmentNotice = model.chat.attachmentNotice {
                    AttachmentNoticeBar(model: model, notice: attachmentNotice)
                }
                switch hudBody {
                case .modelMenu: ModelMenuView(model: model, screen: model.modelMenu)
                case .conversation: ConversationView(model: model)
                case .pinnedList: PinnedListView(model: model)
                case .suggestions: SuggestionList(hud: hud)
                case .focus: FocusView(focus: model.focus, isOpen: hud.isOpen)
                case .caffeine: CaffeineView(caffeine: model.caffeine, isOpen: hud.isOpen)
                case .services: ServicesView(model: model, isOpen: hud.isOpen)
                case .commands: CommandsView(model: model)
                case .settings: SettingsView(model: model)
                case .welcome: WelcomeView(model: model)
                case .empty: EmptyView()
                }
            }
            // A collapsed HUD grows to 160 pt while something is dragged over it.
            .frame(minHeight: dropZone == nil ? nil : HUDStyle.Attachments.dropMinHeight - HUDMetrics.collapsedHeight)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(AccessibilityOrder.body)
        } footer: {
            HUDFooter(left: hud.footerLeft, toastID: hud.toastID) {
                StatusPills(focus: model.focus, caffeine: model.caffeine, isOpen: hud.isOpen)
            }
            // With no body, the header's line is the only one.
            .overlay(alignment: .top) {
                if notice != nil || hudBody != .empty { Hairline() }
            }
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(AccessibilityOrder.footer)
        }
        .overlay {
            if let dropZone { DropZoneOverlay(zone: dropZone) }
        }
        .onDrop(of: [.item], delegate: ImageDropTarget(chat: model.chat, zone: $dropZone))
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
                Group {
                    hud { $0.hud.showSettings(.general) }.previewDisplayName("General")
                    hud(settingsFileProblem: .unreadable(URL(fileURLWithPath: "/tmp/settings.json"))) {
                        $0.hud.showSettings(.general)
                    }
                    .previewDisplayName("General, file problem")
                    hud { $0.hud.open() }.previewDisplayName("Welcome")
                    hud(hotkey: .taken) { $0.hud.open() }.previewDisplayName("Welcome, shortcut taken")
                }
                .preferredColorScheme(scheme)
                Group {
                    hud { $0.hud.selectTab(.focus) }.previewDisplayName("Focus, idle")
                    hud {
                        $0.hud.selectTab(.focus)
                        $0.focus.start()
                    }
                    .previewDisplayName("Focus, running")
                    hud {
                        $0.hud.selectTab(.focus)
                        $0.focus.start()
                        $0.focus.togglePause()
                    }
                    .previewDisplayName("Focus, paused")
                    hud {
                        $0.hud.selectTab(.focus)
                        $0.focus.takeBreakNow()
                    }
                    .previewDisplayName("Break prompt")
                }
                .preferredColorScheme(scheme)
                Group {
                    hud { $0.hud.selectTab(.caffeine) }.previewDisplayName("Caffeine, off")
                    hud {
                        $0.hud.selectTab(.caffeine)
                        $0.caffeine.toggle()
                    }
                    .previewDisplayName("Caffeine, on")
                }
                .preferredColorScheme(scheme)
                Group {
                    hud { $0.hud.selectTab(.services) }.previewDisplayName("Services, empty")
                    hud { $0.hud.showSettings(.services) }.previewDisplayName("Settings → Services")
                    hud {
                        $0.hud.showSettings(.services)
                        $0.services.editService(nil)
                    }
                    .previewDisplayName("New service form")
                }
                .preferredColorScheme(scheme)
                Group {
                    hud { $0.hud.selectTab(.commands) }.previewDisplayName("Commands, empty")
                    hud { $0.hud.showSettings(.commands) }.previewDisplayName("Settings → Commands")
                    hud {
                        $0.hud.showSettings(.commands)
                        $0.commands.editCommand(nil)
                    }
                    .previewDisplayName("New command form")
                }
                .preferredColorScheme(scheme)
                Group {
                    hud {
                        $0.hud.selectTab(.chat)
                        $0.hud.toggleModelMenu()
                    }
                    .previewDisplayName("Model menu, no endpoint")
                    hud {
                        $0.hud.selectTab(.chat)
                        $0.chat.showPreviewConversation()
                    }
                    .previewDisplayName("Conversation")
                    hud { $0.hud.togglePinnedList() }.previewDisplayName("Pinned chats, empty")
                    hud { $0.hud.showSettings(.models) }.previewDisplayName("Settings → Models")
                }
                .preferredColorScheme(scheme)
            }
        }

        private static func hud(
            settingsFileProblem: SettingsFileProblem? = nil, hotkey: HotkeyStatus? = nil,
            _ setUp: (AppModel) -> Void
        ) -> some View {
            let model = AppModel.preview(hotkey: hotkey, settingsFileProblem: settingsFileProblem)
            setUp(model)
            return HUDRootView(model: model)
                .frame(width: HUDLayout.maxWidth)
                .padding(40)
        }
    }
#endif
