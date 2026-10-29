import AppKit
import HeadsUpCore
import UniformTypeIdentifiers

/// The system's open panels: a folder for a service's or command's Choose…, and images for the
/// chat's Attach.
@MainActor
final class OpenPanelsAdapter: OpenPanels {
    func chooseFolder(startingAt path: String) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard await run(panel) == .OK else { return nil }
        return panel.url?.path
    }

    func chooseImages(limit: Int) async -> OfferedImages {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        NSApp.activate(ignoringOtherApps: true)
        guard await run(panel) == .OK else { return OfferedImages(inputs: [], offered: 0) }
        // Every picked file counts; only the ones that fit are read.
        return OfferedImages(inputs: panel.urls.prefix(limit).compactMap(ImageFiles.input), offered: panel.urls.count)
    }

    private func run(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        // Over the HUD, which floats above ordinary windows.
        panel.level = HUDPanel.aboveHUD
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
    }
}

/// Image files as the chat's inputs (F17): a file is read only if its type conforms to
/// `public.image`, and only up to 50 MB; others are skipped. The image port checks the bytes
/// again. Used by the open panel and the pasteboard.
enum ImageFiles {
    static let maxBytes = 50 << 20

    static func input(_ url: URL) -> ImageInput? {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        guard values?.contentType?.conforms(to: .image) == true, (values?.fileSize ?? .max) <= maxBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        return ImageInput(data: data, name: url.lastPathComponent)
    }
}
