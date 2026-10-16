import CoreGraphics
import Foundation
import ImageIO
import TranslatorCore
import UniformTypeIdentifiers

struct ClipboardRawItem: Sendable {
    struct Representation: Sendable { let format: String; let bytes: Data }
    let representations: [Representation]
}
struct ClipboardPreview: @unchecked Sendable {
    // CGImage is immutable; AppKit's NSImage is created only on the main actor.
    let image: CGImage?
    let text: String
    let hasImages: Bool
    let hasFiles: Bool
    let plainTextAvailable: Bool
}

struct ClipboardThumbnail: @unchecked Sendable {
    // CGImage is immutable; only the main actor constructs its NSImage wrapper.
    let image: CGImage
}

/// Bounded image encoding, thumbnail decoding and local OCR run away from AppKit.
protocol ClipboardContentProcessing: Actor {
    func normalize(_ raw: [ClipboardRawItem], maximumBytes: UInt64) async throws -> [ClipboardItem]
    func preview(_ items: [ClipboardItem], ocrText: String) async throws -> ClipboardPreview
    func thumbnail(_ items: [ClipboardItem]) async throws -> ClipboardThumbnail?
    func recognize(_ items: [ClipboardItem]) async throws -> String
}

extension ClipboardContentProcessing {
    func thumbnail(_ items: [ClipboardItem]) async throws -> ClipboardThumbnail? {
        try await preview(items, ocrText: "").image.map { ClipboardThumbnail(image: $0) }
    }
}

actor ClipboardContentProcessor: ClipboardContentProcessing {
    private var ocrBusy = false

    func normalize(_ raw: [ClipboardRawItem], maximumBytes: UInt64) throws -> [ClipboardItem] {
        var total: UInt64 = 0
        return try raw.map { item in
            let representations = try item.representations.map { representation in
                var format = representation.format
                var data = representation.bytes
                if format == "image/png" || format == "image/tiff" {
                    let source = try Self.imageSource(data)
                    if format == "image/tiff" {
                        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ClipboardFailure.InvalidInput }
                        let destinationData = NSMutableData()
                        guard let destination = CGImageDestinationCreateWithData(destinationData as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw ClipboardFailure.InvalidInput }
                        CGImageDestinationAddImage(destination, image, nil)
                        guard CGImageDestinationFinalize(destination) else { throw ClipboardFailure.InvalidInput }
                        data = destinationData as Data
                        format = "image/png"
                    }
                }
                guard UInt64(data.count) <= maximumBytes - total else { throw ClipboardFailure.TooLarge }
                total += UInt64(data.count)
                return ClipboardRepresentation(format: format, bytes: data)
            }
            return ClipboardItem(representations: representations)
        }
    }

    func preview(_ items: [ClipboardItem], ocrText: String) throws -> ClipboardPreview {
        let payload = items.flatMap(\.representations)
        let imageData = payload.first { $0.format == "image/png" }?.bytes
        let thumbnail = try Self.previewImage(payload, maximumPixelSize: 512)
        let text = items.compactMap { item -> String? in
            if let data = item.representations.first(where: { $0.format == "text/plain" })?.bytes {
                return String(data: data, encoding: .utf8)
            }
            if let data = item.representations.first(where: { $0.format == "text/uri-list" })?.bytes,
               let value = String(data: data, encoding: .utf8), let url = URL(string: value) { return url.path }
            return nil
        }.joined(separator: "\n\n")
        return ClipboardPreview(image: thumbnail, text: String((text.isEmpty ? ocrText : text).prefix(20_000)),
                                hasImages: imageData != nil, hasFiles: payload.contains { $0.format == "text/uri-list" },
                                plainTextAvailable: clipboardPlainText(items: items) != nil)
    }

    func thumbnail(_ items: [ClipboardItem]) throws -> ClipboardThumbnail? {
        try Task.checkCancellation()
        let image = try Self.previewImage(items.flatMap(\.representations), maximumPixelSize: 96)
        try Task.checkCancellation()
        return image.map { ClipboardThumbnail(image: $0) }
    }

    private static func previewImage(_ payload: [ClipboardRepresentation], maximumPixelSize: Int) throws -> CGImage? {
        func decode(_ source: CGImageSource) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        if let data = payload.first(where: { $0.format == "image/png" })?.bytes {
            guard let image = decode(try imageSource(data)) else { throw ClipboardFailure.InvalidInput }
            return image
        }
        // Finder copies contain file references, not bitmap data. Read only local
        // regular files and keep the stored reference and copy behavior intact.
        for representation in payload where representation.format == "text/uri-list" {
            try Task.checkCancellation()
            guard let value = String(data: representation.bytes, encoding: .utf8),
                  let url = URL(string: value), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  (try? validateImageSource(source)) != nil,
                  let image = decode(source) else { continue }
            return image
        }
        return nil
    }

    func recognize(_ items: [ClipboardItem]) async throws -> String {
        while ocrBusy { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        ocrBusy = true
        defer { ocrBusy = false }
        var fragments: [String] = []
        for item in items {
            for representation in item.representations where representation.format == "image/png" {
                try Task.checkCancellation()
                let source = try Self.imageSource(representation.bytes)
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OCRError.invalidImage }
                do { fragments.append(try await OCRService().recognizeText(in: image)) }
                catch OCRError.noText { continue }
            }
        }
        try Task.checkCancellation()
        return fragments.joined(separator: "\n\n")
    }

    private static func imageSource(_ data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ClipboardFailure.InvalidInput }
        try validateImageSource(source)
        return source
    }

    private static func validateImageSource(_ source: CGImageSource) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              clipboardImageDimensionsAllowed(width: width.uint64Value, height: height.uint64Value) else { throw ClipboardFailure.TooLarge }
    }
}
