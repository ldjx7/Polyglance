import AppKit
import XCTest
@testable import NativeTranslatorMac

@MainActor
final class ScreenshotFileSaverTests: XCTestCase {
    func testSuggestedFilenameContainsLocalTimestampAndPNGExtension() {
        let date = Date(timeIntervalSince1970: 1_723_622_415.678)
        let timezone = try! XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))

        let name = ScreenshotFileSaver.suggestedFilename(at: date, timeZone: timezone)

        XCTAssertEqual(name, "Polyglance Screenshot 2024-08-14 16.00.15.678.png")
    }

    func testSaveOffersTimestampedFilenameToDestinationChooser() throws {
        let date = Date(timeIntervalSince1970: 1_723_622_415.678)
        let timezone = try! XCTUnwrap(TimeZone(secondsFromGMT: 8 * 60 * 60))
        var offeredName: String?
        let saver = ScreenshotFileSaver(
            now: { date },
            timeZone: timezone,
            chooseDestination: { name in
                offeredName = name
                return nil
            }
        )

        XCTAssertFalse(try saver.save(makeImage(size: CGSize(width: 4, height: 4), color: .red)))
        XCTAssertEqual(offeredName, "Polyglance Screenshot 2024-08-14 16.00.15.678.png")
    }

    func testSaveWritesAReadablePNGToChosenDestination() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: destination) }
        let image = makeImage(size: CGSize(width: 12, height: 8), color: .systemBlue)
        let saver = ScreenshotFileSaver { _ in destination }

        let didSave = try saver.save(image)

        XCTAssertTrue(didSave)
        let savedImage = try XCTUnwrap(NSImage(contentsOf: destination))
        XCTAssertEqual(savedImage.representations.first?.pixelsWide, 12)
        XCTAssertEqual(savedImage.representations.first?.pixelsHigh, 8)
    }

    func testSaveReturnsFalseWhenDestinationSelectionIsCancelled() throws {
        let saver = ScreenshotFileSaver { _ in nil }

        XCTAssertFalse(try saver.save(makeImage(size: CGSize(width: 4, height: 4), color: .red)))
    }

    func testSaveReportsAnEncodingFailureForAnEmptyImage() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let saver = ScreenshotFileSaver { _ in destination }

        XCTAssertThrowsError(try saver.save(NSImage(size: .zero))) { error in
            XCTAssertEqual(error.localizedDescription, "无法将截图编码为 PNG")
        }
    }

    func testSaveReportsAWriteFailure() {
        let saver = ScreenshotFileSaver { _ in FileManager.default.temporaryDirectory }

        XCTAssertThrowsError(
            try saver.save(makeImage(size: CGSize(width: 4, height: 4), color: .red))
        ) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("无法保存截图："))
        }
    }

    private func makeImage(size: CGSize, color: NSColor) -> NSImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }
}
