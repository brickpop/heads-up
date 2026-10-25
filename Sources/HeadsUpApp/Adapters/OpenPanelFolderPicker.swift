import AppKit
import HeadsUpCore

/// The service form's Choose…: an open panel for one folder.
@MainActor
final class OpenPanelFolderPicker: FolderPicker {
    func chooseFolder(startingAt path: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        let answer = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard answer == .OK else { return nil }
        return panel.url?.path
    }
}
