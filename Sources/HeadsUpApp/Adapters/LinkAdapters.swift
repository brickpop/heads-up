import AppKit
import HeadsUpCore
import UniformTypeIdentifiers

/// Opens a link from a reply in the user's default app.
@MainActor
final class WorkspaceLinkOpener: LinkOpener {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The general pasteboard, plain text only.
@MainActor
final class GeneralPasteboard: Pasteboard {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Image data (a screenshot), or image files copied in Finder.
    var hasImages: Bool {
        let board = NSPasteboard.general
        if board.canReadItem(withDataConformingToTypes: [UTType.image.identifier]) { return true }
        return !imageFiles(limit: 1).isEmpty
    }

    /// Image files first, else image data; every one counts, only the ones that fit are read.
    func readImages(limit: Int) -> OfferedImages {
        let files = imageFiles(limit: .max)
        if !files.isEmpty {
            return OfferedImages(inputs: files.prefix(limit).compactMap(ImageFiles.input), offered: files.count)
        }
        let items = (NSPasteboard.general.pasteboardItems ?? []).filter { item in
            item.types.contains { UTType($0.rawValue)?.conforms(to: .image) == true }
        }
        let inputs = items.prefix(limit).compactMap { item -> ImageInput? in
            guard let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                let data = item.data(forType: type), data.count <= ImageFiles.maxBytes
            else { return nil }
            return ImageInput(data: data, name: nil)
        }
        return OfferedImages(inputs: inputs, offered: items.count)
    }

    private func imageFiles(limit: Int) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return Array(
            urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }.prefix(limit))
    }
}
