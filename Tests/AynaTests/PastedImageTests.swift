@testable import Ayna
import Foundation
import Testing

#if !os(watchOS)
    import CoreGraphics
    import ImageIO
    import UniformTypeIdentifiers

    @Suite("PastedImage Tests", .tags(.fast))
    struct PastedImageTests {
        @Test
        func `importing supported PNG preserves original bytes`() throws {
            let pngData = try Self.encodedImage(as: .png)

            let pastedImage = try PastedImage.importing(data: pngData, contentType: .png)

            #expect(pastedImage.data == pngData)
            #expect(pastedImage.mimeType == "image/png")
            #expect(pastedImage.fileExtension == "png")
            #expect(pastedImage.data.count <= PastedImage.maximumByteCount)
        }

        @Test
        func `importing labels the image from its decoded format`() throws {
            let pngData = try Self.encodedImage(as: .png)

            let pastedImage = try PastedImage.importing(data: pngData, contentType: .jpeg)

            #expect(pastedImage.data == pngData)
            #expect(pastedImage.mimeType == "image/png")
            #expect(pastedImage.fileExtension == "png")
        }

        @Test
        func `importing supported PNG rejects bytes that cannot decode`() throws {
            let completePNG = try #require(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            let truncatedPNG = Data(completePNG.prefix(40))
            let source = try #require(CGImageSourceCreateWithData(truncatedPNG as CFData, nil))
            #expect(CGImageSourceGetCount(source) == 1)
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) == nil)

            do {
                _ = try PastedImage.importing(data: truncatedPNG, contentType: .png)
                Issue.record("Expected undecodable PNG bytes to be rejected")
            } catch let error as PastedImage.ImportError {
                guard case .invalidImage = error else {
                    Issue.record("Expected invalidImage, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected PastedImage.ImportError, got \(error)")
            }
        }

        @Test
        func `importing oversized supported PNG resizes instead of preserving bytes`() throws {
            let oversizedPNG = try Self.encodedImage(as: .png, width: 4096, height: 128)
            let originalSource = try #require(CGImageSourceCreateWithData(oversizedPNG as CFData, nil))
            let originalImage = try #require(CGImageSourceCreateImageAtIndex(originalSource, 0, nil))
            #expect(max(originalImage.width, originalImage.height) > 2048)
            #expect(oversizedPNG.count <= PastedImage.maximumByteCount)

            let pastedImage = try PastedImage.importing(data: oversizedPNG, contentType: .png)

            #expect(pastedImage.data != oversizedPNG)
            #expect(pastedImage.data.count <= PastedImage.maximumByteCount)
            #expect(["image/png", "image/jpeg"].contains(pastedImage.mimeType))
            #expect(["png", "jpg"].contains(pastedImage.fileExtension))
            let resizedSource = try #require(CGImageSourceCreateWithData(pastedImage.data as CFData, nil))
            let resizedImage = try #require(CGImageSourceCreateImageAtIndex(resizedSource, 0, nil))
            #expect(max(resizedImage.width, resizedImage.height) <= 2048)
        }

        @Test
        func `importing TIFF converts to a provider-safe image`() throws {
            let tiffData = try Self.encodedImage(as: .tiff)

            let pastedImage = try PastedImage.importing(data: tiffData, contentType: .tiff)

            #expect(pastedImage.data != tiffData)
            #expect(!pastedImage.data.isEmpty)
            #expect(pastedImage.data.count <= PastedImage.maximumByteCount)

            let expectedContentType: UTType
            switch pastedImage.mimeType {
            case "image/png":
                #expect(pastedImage.fileExtension == "png")
                expectedContentType = .png
            case "image/jpeg":
                #expect(pastedImage.fileExtension == "jpg")
                expectedContentType = .jpeg
            default:
                Issue.record("Expected a PNG or JPEG conversion, got \(pastedImage.mimeType)")
                return
            }

            let source = try #require(CGImageSourceCreateWithData(pastedImage.data as CFData, nil))
            #expect(CGImageSourceGetCount(source) == 1)
            #expect(CGImageSourceGetType(source) as String? == expectedContentType.identifier)
        }

        @Test
        func `converting applies EXIF orientation to the image pixels`() throws {
            let orientedTIFF = try Self.encodedImage(
                as: .tiff,
                width: 96,
                height: 64,
                properties: [kCGImagePropertyOrientation: 6]
            )
            let originalSource = try #require(CGImageSourceCreateWithData(orientedTIFF as CFData, nil))
            let originalProperties = try #require(
                CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as NSDictionary?
            )
            #expect((originalProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 96)
            #expect((originalProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 64)
            #expect((originalProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == 6)

            let pastedImage = try PastedImage.importing(data: orientedTIFF, contentType: .tiff)

            let convertedSource = try #require(CGImageSourceCreateWithData(pastedImage.data as CFData, nil))
            let convertedImage = try #require(CGImageSourceCreateImageAtIndex(convertedSource, 0, nil))
            #expect(convertedImage.width == 64)
            #expect(convertedImage.height == 96)
        }

        @Test
        func `importing invalid bytes rejects the image`() {
            do {
                _ = try PastedImage.importing(
                    data: Data("not an image".utf8),
                    contentType: .png
                )
                Issue.record("Expected invalid image bytes to be rejected")
            } catch let error as PastedImage.ImportError {
                guard case .invalidImage = error else {
                    Issue.record("Expected invalidImage, got \(error)")
                    return
                }
            } catch {
                Issue.record("Expected PastedImage.ImportError, got \(error)")
            }
        }

        private static func encodedImage(
            as contentType: UTType,
            width: Int = 96,
            height: Int = 64,
            properties: [CFString: Any]? = nil
        ) throws -> Data {
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                throw PastedImageFixtureError.contextCreationFailed
            }

            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 0.75))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 0.5))
            context.fill(CGRect(x: 24, y: 16, width: 48, height: 32))

            guard let image = context.makeImage() else {
                throw PastedImageFixtureError.imageCreationFailed
            }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                contentType.identifier as CFString,
                1,
                nil
            ) else {
                throw PastedImageFixtureError.destinationCreationFailed
            }
            CGImageDestinationAddImage(
                destination,
                image,
                properties.map { $0 as CFDictionary }
            )
            guard CGImageDestinationFinalize(destination) else {
                throw PastedImageFixtureError.encodingFailed
            }
            return output as Data
        }
    }

    private enum PastedImageFixtureError: Error {
        case contextCreationFailed
        case imageCreationFailed
        case destinationCreationFailed
        case encodingFailed
    }
#endif
