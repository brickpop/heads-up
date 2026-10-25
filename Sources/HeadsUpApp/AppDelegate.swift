import AppKit
import Carbon.HIToolbox
import os

/// Creates the HUD panel and the wake shortcut at launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HeadsUp", category: "app")
    private var panel: HUDPanel?
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = HUDPanel()
        self.panel = panel

        // ⌥ Space. Slice 1 makes the shortcut a setting and reports a failure in the UI.
        do {
            hotkey = try Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)) {
                panel.toggle()
            }
            log.info("wake shortcut registered")
        } catch {
            log.error("wake shortcut not registered: OSStatus \(error.status, privacy: .public)")
        }
    }
}
