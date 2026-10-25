import AppKit
import HeadsUpCore
import UniformTypeIdentifiers

/// Reads the images dragged onto the HUD: the UI glue between AppKit's item providers and
/// `chat.attach(_:)`.
///
/// A file from Finder is read through `ImageFiles.input(url)`, so its type and size are checked
/// before any byte is read. Raw image data (from a browser, or the screenshot thumbnail) is read
/// up to `ImageFiles.maxBytes`. Decoding, stripping and the per-message limit are the core's (F17).
@MainActor
enum ImageDropReader {
    /// How many of the dragged items are images, and how many aren't, for the drop zone.
    static func count(_ providers: [NSItemProvider]) -> (images: Int, others: Int) {
        let images = providers.filter(isImage).count
        return (images, providers.count - images)
    }

    /// Loads the images, in the order they were dragged: at most what one message takes. The
    /// caller tells the core how many were offered, so it can say how many weren't added.
    static func read(_ providers: [NSItemProvider]) async -> [ImageInput] {
        var inputs: [ImageInput] = []
        for provider in providers.filter(isImage).prefix(ChatStore.maxImages) {
            if let input = await load(provider) { inputs.append(input) }
        }
        return inputs
    }

    private static func isImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    private static func load(_ provider: NSItemProvider) async -> ImageInput? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.flatMap(ImageFiles.input))
                }
            }
        }
        let name = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, data.count <= ImageFiles.maxBytes else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ImageInput(data: data, name: name))
            }
        }
    }
}
