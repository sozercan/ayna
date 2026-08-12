//
//  PastedImage.swift
//  Ayna
//

#if !os(watchOS)

    import CoreGraphics
    import CoreTransferable
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    /// An image imported from the clipboard and normalized for vision-capable providers.
    struct PastedImage: Identifiable, Equatable, Sendable {
        enum ImportError: LocalizedError {
            case invalidImage
            case conversionFailed
            case imageTooLarge

            var errorDescription: String? {
                switch self {
                case .invalidImage:
                    "The clipboard does not contain a valid image."
                case .conversionFailed:
                    "The clipboard image could not be converted."
                case .imageTooLarge:
                    "The clipboard image is too large to attach."
                }
            }
        }

        /// Matches the strictest supported provider limit (Anthropic: 3.75 MiB).
        static let maximumByteCount = 3_932_160
        static let maximumDimension = 2048

        let id: UUID
        let data: Data
        let mimeType: String
        let fileExtension: String

        init(
            id: UUID = UUID(),
            data: Data,
            mimeType: String,
            fileExtension: String
        ) {
            self.id = id
            self.data = data
            self.mimeType = mimeType
            self.fileExtension = fileExtension.lowercased()
        }

        var fileName: String {
            "pasted-image-\(id.uuidString.lowercased()).\(fileExtension)"
        }

        /// Validates clipboard bytes and converts formats that providers cannot consume directly.
        static func importing(data: Data, contentType: UTType) throws -> PastedImage {
            guard !data.isEmpty,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let dimensions = pixelDimensions(of: source)
            else {
                throw ImportError.invalidImage
            }

            let decodedContentType = CGImageSourceGetType(source)
                .flatMap { UTType($0 as String) }
            if let format = providerFormat(for: decodedContentType ?? contentType),
               data.count <= maximumByteCount,
               max(dimensions.width, dimensions.height) <= maximumDimension
            {
                guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                    throw ImportError.invalidImage
                }
                return PastedImage(
                    data: data,
                    mimeType: format.mimeType,
                    fileExtension: format.fileExtension
                )
            }

            guard let sourceImage = transformedThumbnail(from: source) else {
                throw ImportError.invalidImage
            }
            return try convertedImage(from: sourceImage)
        }

        private static func pixelDimensions(of source: CGImageSource) -> (width: Int, height: Int)? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0
            else {
                return nil
            }
            return (width, height)
        }

        private static func transformedThumbnail(from source: CGImageSource) -> CGImage? {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        private static func providerFormat(for contentType: UTType) -> (mimeType: String, fileExtension: String)? {
            if contentType.conforms(to: .jpeg) {
                return ("image/jpeg", "jpg")
            }
            if contentType.conforms(to: .png) {
                return ("image/png", "png")
            }
            if contentType.conforms(to: .gif) {
                return ("image/gif", "gif")
            }
            if contentType.conforms(to: .webP) {
                return ("image/webp", "webp")
            }
            return nil
        }

        private static func convertedImage(from sourceImage: CGImage) throws -> PastedImage {
            let outputType: UTType = hasAlpha(sourceImage) ? .png : .jpeg
            var image = resized(sourceImage, maximumDimension: maximumDimension) ?? sourceImage

            while true {
                let qualityValues: [CGFloat] = outputType == .jpeg
                    ? [0.85, 0.7, 0.55, 0.4, 0.25]
                    : [1.0]

                for quality in qualityValues {
                    guard let encoded = encode(image, as: outputType, quality: quality) else {
                        continue
                    }
                    if encoded.count <= maximumByteCount {
                        return PastedImage(
                            data: encoded,
                            mimeType: outputType == .png ? "image/png" : "image/jpeg",
                            fileExtension: outputType == .png ? "png" : "jpg"
                        )
                    }
                }

                let largestDimension = max(image.width, image.height)
                guard largestDimension > 64 else {
                    throw ImportError.imageTooLarge
                }
                guard let smallerImage = resized(
                    image,
                    maximumDimension: max(64, Int(Double(largestDimension) * 0.75))
                ) else {
                    throw ImportError.conversionFailed
                }
                image = smallerImage
            }
        }

        private static func encode(_ image: CGImage, as contentType: UTType, quality: CGFloat) -> Data? {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                contentType.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }

            let properties: CFDictionary? = if contentType == .jpeg {
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            } else {
                nil
            }
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }

        private static func resized(_ image: CGImage, maximumDimension: Int) -> CGImage? {
            let largestDimension = max(image.width, image.height)
            guard largestDimension > maximumDimension else { return image }

            let scale = CGFloat(maximumDimension) / CGFloat(largestDimension)
            let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }

        private static func hasAlpha(_ image: CGImage) -> Bool {
            switch image.alphaInfo {
            case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
                true
            case .none, .noneSkipFirst, .noneSkipLast:
                false
            @unknown default:
                false
            }
        }
    }

    extension PastedImage: Transferable {
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(importedContentType: .png) { data in
                try importing(data: data, contentType: .png)
            }
            DataRepresentation(importedContentType: .jpeg) { data in
                try importing(data: data, contentType: .jpeg)
            }
            DataRepresentation(importedContentType: .gif) { data in
                try importing(data: data, contentType: .gif)
            }
            DataRepresentation(importedContentType: .webP) { data in
                try importing(data: data, contentType: .webP)
            }
            DataRepresentation(importedContentType: .tiff) { data in
                try importing(data: data, contentType: .tiff)
            }
            DataRepresentation(importedContentType: .heic) { data in
                try importing(data: data, contentType: .heic)
            }
        }
    }

#endif
