import FlotsamBase
import Foundation
import ImageIO

/// An image after the FR-007-07 pipeline: the bytes to store, and the pixel size of those bytes.
struct ProcessedImage: Sendable {
    let data: Data
    let uti: String
    /// The stored blob's dimensions, after any downscale (FR-007-07 step 2). They are what the Library shows and what
    /// the budget's bytes correspond to; the copied original's size is deliberately not kept.
    let width: Int
    let height: Int
}

/// Decode, convert, downscale and thumbnail with ImageIO only, one image at a time (FR-007-07).
///
/// An actor because "one image in flight" is the memory guarantee: a 100 MiB source decodes to several hundred
/// MB of pixels, and two at once would blow the 150 MB budget (FR-007-16). Ingest and thumbnail generation share
/// the one instance, so they queue behind each other rather than overlapping.
actor ImageWorker {
    static let pngType = "public.png"
    static let jpegType = "public.jpeg"
    static let tiffType = "public.tiff"
    /// Quality for a re-encoded (downscaled) JPEG (FR-007-08).
    static let storedJPEGQuality = 0.85
    /// Quality for thumbnails (FR-007-07).
    static let thumbnailJPEGQuality = 0.8

    /// The longest-edge ceiling a preset applies to new images; nil means store as received.
    static func edgeCeiling(for quality: ImageQuality) -> Int? {
        switch quality {
        case .original: nil
        case .balanced: 3840
        case .efficient: 2560
        }
    }

    /// Returns nil when the bytes are not a decodable image (the caller reports `CAP-VAL-001` or `SSP-VAL-001`).
    ///
    /// Only PNG, JPEG and TIFF are ever re-encoded. Anything else ImageIO can read (GIF, HEIC, WebP) is stored as
    /// received and never downscaled: re-encoding would drop animation or colour profile and the FRD defines a
    /// downscaled format only for PNG and JPEG.
    ///
    /// Format rule (FR-007-07 step 3, FR-007-08): a TIFF becomes PNG; then an opaque PNG becomes JPEG when it was
    /// downscaled or the preset is Efficient, and an image with transparency stays PNG. A JPEG is only re-encoded when
    /// it is downscaled, so an untouched JPEG never loses quality.
    func process(_ data: Data, receivedUTI: String, quality: ImageQuality) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }

        let asReceived = ProcessedImage(data: data, uti: receivedUTI, width: width, height: height)
        guard [Self.pngType, Self.jpegType, Self.tiffType].contains(sourceType) else { return asReceived }

        var scaled: CGImage?
        if let ceiling = Self.edgeCeiling(for: quality), max(width, height) > ceiling {
            guard let image = Self.scaledImage(source, longestEdge: ceiling) else { return nil }
            scaled = image
        }

        if sourceType == Self.jpegType {
            guard let scaled else { return asReceived }
            guard let jpeg = Self.encode(scaled, type: Self.jpegType, quality: Self.storedJPEGQuality) else { return nil }
            return ProcessedImage(data: jpeg, uti: Self.jpegType, width: scaled.width, height: scaled.height)
        }

        // PNG or TIFF. Nothing to change: a PNG that was neither downscaled nor converted keeps its exact bytes
        // (Original and Balanced, or an Efficient PNG that has transparency and is already small enough).
        let opaqueToJPEG = scaled != nil || quality == .efficient
        if sourceType == Self.pngType, !opaqueToJPEG { return asReceived }
        // The decode is bounded: an image that was not downscaled is at or under the preset's ceiling, and the
        // un-capped Original preset only reaches this line for a TIFF, which has to be decoded to become PNG anyway.
        guard let image = scaled ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        if opaqueToJPEG, !Self.hasTransparency(image) {
            guard let jpeg = Self.encode(image, type: Self.jpegType, quality: Self.storedJPEGQuality) else { return nil }
            return ProcessedImage(data: jpeg, uti: Self.jpegType, width: image.width, height: image.height)
        }
        // A PNG whose pixels were not touched keeps its received bytes; anything decoded or resized is re-encoded.
        if sourceType == Self.pngType, scaled == nil { return asReceived }
        guard let png = Self.encode(image, type: Self.pngType, quality: nil) else { return nil }
        return ProcessedImage(data: png, uti: Self.pngType, width: image.width, height: image.height)
    }

    /// A JPEG thumbnail whose longest edge is `edge`, or nil if the bytes cannot be decoded.
    func thumbnail(from data: Data, edge: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let scaled = Self.scaledImage(source, longestEdge: edge)
        else { return nil }
        return Self.encode(scaled, type: Self.jpegType, quality: Self.thumbnailJPEGQuality)
    }

    // MARK: ImageIO helpers

    /// Decodes straight to the target size (never the full bitmap first), honouring EXIF orientation.
    private static func scaledImage(_ source: CGImageSource, longestEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encode(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// True when any pixel is not fully opaque. The PNG "has alpha" property is not enough: macOS screenshots
    /// carry an alpha channel that is opaque everywhere, and those must still become JPEG (FR-007-08).
    private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        // If the scan itself cannot run, keep the transparency: losing alpha is worse than a larger PNG.
        guard drawn else { return true }
        var index = 3
        while index < pixels.count {
            if pixels[index] != 255 { return true }
            index += 4
        }
        return false
    }
}
