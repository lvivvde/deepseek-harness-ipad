import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO behind the slice of the `sharp` API the official attachment store uses: metadata, a full
/// decode check, and an oriented sRGB resize re-encoded as JPEG. iOS has no WebP encoder, so the
/// store's WebP path (images with alpha that need re-encoding) fails with an explicit code.
public struct NativeImageCodec: Sendable {
    public struct Metadata: Equatable, Sendable {
        public var format: String
        public var width: Int
        public var height: Int
        public var pages: Int
        public var orientation: Int?
        public var depth: String
        public var space: String
        public var hasAlpha: Bool
        public var hasProfile: Bool
        public var exif: Bool
    }

    public struct EncodeOptions: Sendable {
        public var rotate: Bool
        public var width: Int?
        public var height: Int?
        public var withoutEnlargement: Bool
        public var format: String
        public var quality: Int
        public init(rotate: Bool, width: Int?, height: Int?, withoutEnlargement: Bool, format: String, quality: Int) {
            self.rotate = rotate; self.width = width; self.height = height
            self.withoutEnlargement = withoutEnlargement; self.format = format; self.quality = quality
        }
    }

    public struct Encoded: Sendable {
        public var data: Data
        public var width: Int
        public var height: Int
    }

    static let formats: [String: String] = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpeg",
                                            UTType.webP.identifier: "webp", UTType.gif.identifier: "gif"]

    public init() {}

    public func metadata(_ data: Data) throws -> Metadata {
        let source = try self.source(data)
        guard let type = CGImageSourceGetType(source) as String?, let format = Self.formats[type],
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw Self.invalid }
        let orientation = (properties[kCGImagePropertyOrientation] as? Int).flatMap { $0 == 1 && format == "png" ? nil : $0 }
        let model = properties[kCGImagePropertyColorModel] as? String
        let profile = properties[kCGImagePropertyProfileName] as? String
        return Metadata(format: format, width: width, height: height, pages: CGImageSourceGetCount(source), orientation: orientation,
                        depth: (properties[kCGImagePropertyDepth] as? Int ?? 8) > 8 ? "ushort" : "uchar",
                        space: model == "Gray" ? "b-w" : model == "CMYK" ? "cmyk" : model == "Lab" ? "lab" : "srgb",
                        hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
                        // Any embedded profile other than plain sRGB counts, so the store re-encodes rather than trusts it.
                        hasProfile: profile.map { !$0.hasPrefix("sRGB") } ?? false,
                        exif: properties[kCGImagePropertyExifDictionary] != nil && format != "png")
    }

    /// Decodes every pixel of the first frame; truncated or corrupt data fails.
    public func decode(_ data: Data) throws {
        let source = try self.source(data)
        // ImageIO decodes a truncated file and still reports it complete; libvips with failOn 'error' refuses it.
        guard let format = CGImageSourceGetType(source).flatMap({ Self.formats[$0 as String] }), Self.terminated(data, format),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              draw(image, width: image.width, height: image.height, alpha: true) != nil
        else { throw Self.invalid }
    }

    public func encode(_ data: Data, options: EncodeOptions) throws -> Encoded {
        guard options.format == "jpeg" else { throw ToolError("IMAGE_ENCODER_UNAVAILABLE", "no native \(options.format) encoder") }
        let meta = try metadata(data)
        try decode(data)
        let source = try self.source(data)
        let transposed = options.rotate && (meta.orientation ?? 1) >= 5
        let (sourceWidth, sourceHeight) = transposed ? (meta.height, meta.width) : (meta.width, meta.height)
        var scale = 1.0
        if let width = options.width { scale = Double(width) / Double(sourceWidth) }
        if let height = options.height { scale = options.width == nil ? Double(height) / Double(sourceHeight) : min(scale, Double(height) / Double(sourceHeight)) }
        if options.withoutEnlargement { scale = min(scale, 1) }
        let width = max(1, Int((Double(sourceWidth) * scale).rounded())), height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        // The thumbnail API applies the EXIF orientation when asked; it never enlarges past MaxPixelSize.
        let thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                          kCGImageSourceCreateThumbnailWithTransform: options.rotate,
                                          kCGImageSourceThumbnailMaxPixelSize: max(meta.width, meta.height)]
        guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary),
              let context = draw(full, width: width, height: height, alpha: false), let resized = context.makeImage()
        else { throw Self.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Self.invalid }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: Double(options.quality) / 100] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ToolError("IMAGE_ENCODE_FAILED") }
        return Encoded(data: output as Data, width: width, height: height)
    }

    /// Whether the container ends where its format says it does.
    static func terminated(_ data: Data, _ format: String) -> Bool {
        let bytes = [UInt8](data)
        switch format {
        case "png": return bytes.count >= 12 && Array(bytes.suffix(8)) == [0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        case "jpeg": return bytes.suffix(2) == [0xFF, 0xD9]
        case "gif": return bytes.last == 0x3B
        case "webp":
            guard bytes.count >= 12 else { return false }
            let size = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
            return size + 8 <= bytes.count
        default: return false
        }
    }

    static let invalid = ToolError("INVALID_IMAGE", "Unsupported or malformed image data.")

    func source(_ data: Data) throws -> CGImageSource {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw Self.invalid }
        return source
    }

    /// Draws into an 8-bit sRGB bitmap, which converts the colour space and scales in one pass.
    func draw(_ image: CGImage, width: Int, height: Int, alpha: Bool) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
