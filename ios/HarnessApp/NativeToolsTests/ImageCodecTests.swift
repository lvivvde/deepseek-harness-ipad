import CoreGraphics
import ImageIO
@testable import NativeTools
import UniformTypeIdentifiers
import XCTest

final class ImageCodecTests: XCTestCase {
    let codec = NativeImageCodec()

    /// A solid image encoded by ImageIO, optionally with alpha and an EXIF orientation.
    func image(_ type: UTType, width: Int, height: Int, alpha: Bool = false, orientation: Int? = nil) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testMetadataReportsSharpFieldsForAPlainPng() throws {
        let meta = try codec.metadata(try image(.png, width: 4, height: 3))
        XCTAssertEqual(meta.format, "png")
        XCTAssertEqual(meta.width, 4)
        XCTAssertEqual(meta.height, 3)
        XCTAssertEqual(meta.pages, 1)
        XCTAssertEqual(meta.depth, "uchar")
        XCTAssertEqual(meta.space, "srgb")
        XCTAssertFalse(meta.hasAlpha)
        XCTAssertNil(meta.orientation)
    }

    func testMetadataSeesAlphaAndOrientation() throws {
        XCTAssertTrue(try codec.metadata(try image(.png, width: 2, height: 2, alpha: true)).hasAlpha)
        let rotated = try codec.metadata(try image(.jpeg, width: 4, height: 2, orientation: 6))
        XCTAssertEqual(rotated.format, "jpeg")
        XCTAssertEqual(rotated.orientation, 6)
        // Sharp reports stored dimensions; the official caller transposes for orientation >= 5.
        XCTAssertEqual([rotated.width, rotated.height], [4, 2])
    }

    func testDecodeRefusesTruncatedAndUnknownBytes() throws {
        let png = try image(.png, width: 64, height: 64)
        XCTAssertNoThrow(try codec.decode(png))
        XCTAssertThrowsError(try codec.decode(png.prefix(png.count / 2))) { XCTAssertEqual(($0 as? ToolError)?.code, "INVALID_IMAGE") }
        XCTAssertThrowsError(try codec.metadata(Data("not an image".utf8))) { XCTAssertEqual(($0 as? ToolError)?.code, "INVALID_IMAGE") }
        XCTAssertThrowsError(try codec.metadata(try image(.tiff, width: 2, height: 2))) { XCTAssertEqual(($0 as? ToolError)?.code, "INVALID_IMAGE") }
    }

    func testEncodeResizesInsideAndAppliesOrientation() throws {
        let wide = try codec.encode(try image(.png, width: 400, height: 200),
                                    options: .init(rotate: false, width: 100, height: nil, withoutEnlargement: true, format: "jpeg", quality: 85))
        XCTAssertEqual([wide.width, wide.height], [100, 50])
        XCTAssertEqual(try codec.metadata(wide.data).format, "jpeg")
        // Orientation 6 stores 4x2 and displays 2x4; rotate() bakes it in and drops the tag.
        let upright = try codec.encode(try image(.jpeg, width: 4, height: 2, orientation: 6),
                                       options: .init(rotate: true, width: nil, height: nil, withoutEnlargement: true, format: "jpeg", quality: 75))
        XCTAssertEqual([upright.width, upright.height], [2, 4])
        XCTAssertNil(try codec.metadata(upright.data).orientation)
        let small = try codec.encode(try image(.png, width: 10, height: 10),
                                     options: .init(rotate: false, width: 50, height: 50, withoutEnlargement: true, format: "jpeg", quality: 60))
        XCTAssertEqual([small.width, small.height], [10, 10])
    }

    func testWebpEncodingIsRefusedExplicitly() throws {
        XCTAssertThrowsError(try codec.encode(try image(.png, width: 2, height: 2, alpha: true),
                                              options: .init(rotate: true, width: 1, height: 1, withoutEnlargement: true, format: "webp", quality: 85))) {
            XCTAssertEqual(($0 as? ToolError)?.code, "IMAGE_ENCODER_UNAVAILABLE")
        }
    }
}
