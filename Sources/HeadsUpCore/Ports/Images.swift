import Foundation

/// An image the user gave: picked, pasted or dropped, not yet decoded (threat model F17).
public struct ImageInput: Equatable, Sendable {
    public let data: Data
    /// "Screenshot 1.png", or nil for pasted data.
    public let name: String?

    public init(data: Data, name: String?) {
        self.data = data
        self.name = name
    }
}

/// An image ready to send and to keep: decoded with a pixel limit, re-encoded without
/// metadata (no location), and a small preview.
public struct ProcessedImage: Equatable, Sendable {
    public enum MIME: String, Sendable {
        case jpeg = "image/jpeg"
        case png = "image/png"
    }

    public let data: Data
    public let mime: MIME
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// A PNG at most 240 × 160, for thumbnails.
    public let preview: Data

    public init(data: Data, mime: MIME, pixelWidth: Int, pixelHeight: Int, preview: Data) {
        self.data = data
        self.mime = mime
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.preview = preview
    }

    /// "data:image/jpeg;base64,…", as the chat-completions API takes it.
    var dataURL: String { "data:\(mime.rawValue);base64,\(data.base64EncodedString())" }
}

public enum ImageError: Error, Equatable, Sendable {
    /// Not one of the allowed image types (`ImageLimits.allowedTypes`), or ImageIO can't read it.
    case notAnImage
    /// Bigger than `ImageLimits` allows: refused before it is decoded (Scan L1).
    case tooLarge
}

/// What an image must be before it is decoded (F17; Scan L1, L2). The macOS adapter reads the
/// type and the pixel size from the file's header, without decoding it, and asks `check`.
public enum ImageLimits {
    /// The types ImageIO may decode for the chat, by the type it reads from the bytes. No PDF,
    /// no SVG, no RAW: only common photo and screenshot formats.
    public static let allowedTypes: Set<String> = [
        "public.png", "public.jpeg", "public.heic", "com.compuserve.gif", "org.webmproject.webp", "public.tiff",
    ]
    /// At most 100 megapixels, and at most 20,000 px on either side.
    public static let maxPixels = 100_000_000
    public static let maxSide = 20_000

    /// Throws unless the type is allowed and the size is within the limits. A size the header
    /// doesn't give (0) is refused too.
    public static func check(type: String?, width: Int, height: Int) throws(ImageError) {
        guard let type, allowedTypes.contains(type) else { throw .notAnImage }
        guard width > 0, height > 0 else { throw .notAnImage }
        guard width <= maxSide, height <= maxSide, width * height <= maxPixels else { throw .tooLarge }
    }
}

/// Decodes and re-encodes images (ADR-001 §6.4, F17). The macOS adapter reads the type from
/// the bytes themselves and refuses anything that isn't a raster `public.image` (a PDF too). It
/// uses ImageIO's thumbnail decoding with a 2048 px limit, never `NSImage(contentsOf:)`, and
/// writes JPEG q0.85, or PNG for images with alpha, without metadata. It may take a while:
/// callers run it off the main actor.
public protocol ImageProcessor: Sendable {
    func process(_ input: ImageInput) throws(ImageError) -> ProcessedImage
    /// A thumbnail at most 240 × 160 of an image already processed, for a loaded pin.
    func preview(_ data: Data) throws(ImageError) -> Data
}

/// Images the user offered: the ones read, and how many there were in all, so the chat can say
/// how many weren't added.
public struct OfferedImages: Equatable, Sendable {
    public let inputs: [ImageInput]
    public let offered: Int

    public init(inputs: [ImageInput], offered: Int) {
        self.inputs = inputs
        self.offered = max(offered, inputs.count)
    }
}

/// The system's open panels: a folder for a service or command, images for the chat.
@MainActor
public protocol OpenPanels: AnyObject {
    /// The folder's path, or nil if the user cancelled. The panel opens on `path`.
    func chooseFolder(startingAt path: String) async -> String?
    /// The images the user picked: the first `limit` read, and how many were picked in all.
    func chooseImages(limit: Int) async -> OfferedImages
}
