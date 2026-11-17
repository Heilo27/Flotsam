import FlotsamBase
import Foundation
import ImageIO

/// An image after the FR-007-07 pipeline: the bytes to store, and the source's own dimensions.
struct ProcessedImage: Sendable {
    let data: Data
    let uti: String
    /// The source's dimensions, not the stored image's: `pixelWidth` and `pixelHeight` describe what was copied
    /// (FR-007-07 step 2 records them before any downscale).
    let sourceWidth: Int
    let sourceHeight: Int
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
    func process(_ data: Data, receivedUTI: String, quality: ImageQuality) -> ProcessedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }

        let reencodable = [Self.pngType, Self.jpegType, Self.tiffType].contains(sourceType)
        let sourceStored = ProcessedImage(data: data, uti: receivedUTI, sourceWidth: width, sourceHeight: height)
        guard reencodable else { return sourceStored }

        let ceiling = Self.edgeCeiling(for: quality)
        if let ceiling, max(width, height) > ceiling {
            guard let scaled = Self.scaledImage(source, longestEdge: ceiling) else { return nil }
            // Opaque PNG becomes JPEG; transparency keeps PNG; a JPEG stays a JPEG (FR-007-08).
            let keepsPNG = sourceType != Self.jpegType && Self.hasTransparency(scaled)
            let encoded = keepsPNG
                ? Self.encode(scaled, type: Self.pngType, quality: nil)
                : Self.encode(scaled, type: Self.jpegType, quality: Self.storedJPEGQuality)
            guard let encoded else { return nil }
            return ProcessedImage(
                data: encoded, uti: keepsPNG ? Self.pngType : Self.jpegType, sourceWidth: width, sourceHeight: height)
        }

        guard sourceType == Self.tiffType else { return sourceStored }
        // TIFF is converted to lossless PNG whatever the preset (FR-007-07 step 3).
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let png = Self.encode(image, type: Self.pngType, quality: nil)
        else { return nil }
        return ProcessedImage(data: png, uti: Self.pngType, sourceWidth: width, sourceHeight: height)
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
