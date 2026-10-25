import AppKit
import HeadsUpCore
import ImageIO
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

extension GeneralPasteboard {
    /// The markers password managers (1Password, Bitwarden, the macOS Passwords app) put on
    /// what they copy (nspasteboard.org).
    static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]

    /// What `clipboard_read` would share (F3). A marked item is refused before anything of it
    /// is read; files are listed by name only; an image gives only its size.
    func toolContents() -> ClipboardContents {
        let board = NSPasteboard.general
        let types = Set((board.types ?? []).map(\.rawValue))
            .union((board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        if !types.isDisjoint(with: Self.concealedTypes) { return .concealed }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            return .files(files.map(\.lastPathComponent))
        }
        if let text = board.string(forType: .string) {
            return text.isEmpty ? .empty : .text(text)
        }
        for item in board.pasteboardItems ?? [] {
            guard let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
                let data = item.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData, nil),
                // Only the types the chat accepts, by what ImageIO reads from the bytes (Scan I19).
                let sourceType = CGImageSourceGetType(source) as String?, ImageLimits.allowedTypes.contains(sourceType),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { continue }
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            return .image(width: width, height: height)
        }
        return .empty
    }
}
