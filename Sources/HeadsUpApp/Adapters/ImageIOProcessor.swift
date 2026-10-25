import Foundation
import HeadsUpCore
import ImageIO
import UniformTypeIdentifiers

/// Decodes and re-encodes chat images with ImageIO (ADR-001 §6.4, F17). The header is checked
/// first: only the types in `ImageLimits.allowedTypes`, and no decompression bombs. Then
/// thumbnail decoding at
/// most 2048 px on the long side, never `NSImage(contentsOf:)`; JPEG q0.85, or PNG when the
/// image has alpha; no metadata is copied, so no location leaves the Mac. A preview PNG at most
/// 240 × 160 goes with it.
final class ImageIOProcessor: ImageProcessor {
    static let maxPixels = 2048

    func process(_ input: ImageInput) throws(ImageError) -> ProcessedImage {
        let source = try Self.checkedSource(input.data)
        guard let image = Self.thumbnail(source, maxPixels: Self.maxPixels) else { throw .notAnImage }
        let alpha: [CGImageAlphaInfo] = [.first, .last, .premultipliedFirst, .premultipliedLast]
        let mime: ProcessedImage.MIME = alpha.contains(image.alphaInfo) ? .png : .jpeg
        guard let data = Self.encode(image, as: mime),
            let preview = Self.thumbnail(source, maxPixels: 240).flatMap({ Self.encode($0, as: .png) })
        else { throw .notAnImage }
        return ProcessedImage(
            data: data, mime: mime, pixelWidth: image.width, pixelHeight: image.height, preview: preview)
    }

    /// The thumbnail of an image this processor already wrote, for a loaded pin.
    func preview(_ data: Data) throws(ImageError) -> Data {
        let source = try Self.checkedSource(data)
        guard let preview = Self.thumbnail(source, maxPixels: 240).flatMap({ Self.encode($0, as: .png) }) else {
            throw .notAnImage
        }
        return preview
    }

    /// A source whose header passes `ImageLimits` (Scan L1, L2): the type ImageIO reads from the
    /// bytes, whatever the file was called, and the pixel size, both read without decoding.
    private static func checkedSource(_ data: Data) throws(ImageError) -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { throw .notAnImage }
        let type = CGImageSourceGetType(source) as String?
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        try ImageLimits.check(type: type, width: width, height: height)
        return source
    }

    private static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image alone: no properties are passed, so no EXIF, GPS or other metadata is written.
    private static func encode(_ image: CGImage, as mime: ProcessedImage.MIME) -> Data? {
        let data = NSMutableData()
        let type = (mime == .png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options: [CFString: Any] = mime == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
