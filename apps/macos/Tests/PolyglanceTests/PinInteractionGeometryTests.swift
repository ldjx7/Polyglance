import CoreGraphics
import XCTest
@testable import Polyglance

final class PinInteractionGeometryTests: XCTestCase {
    func testScalingKeepsThePointUnderThePointerFixed() {
        let frame = CGRect(x: 100, y: 80, width: 200, height: 120)
        let anchor = CGPoint(x: 50, y: 30)

        let scaled = PinResizeGeometry.scaledFrame(
            frame,
            requestedScale: 1.5,
            anchorInWindow: anchor,
            minimumSize: CGSize(width: 80, height: 48),
            maximumSize: CGSize(width: 800, height: 480)
        )

        XCTAssertEqual(scaled.width, 300, accuracy: 0.001)
        XCTAssertEqual(scaled.height, 180, accuracy: 0.001)
        assertAnchorIsStable(oldFrame: frame, newFrame: scaled, anchor: anchor)
    }

    func testScalingClampsAtMaximumSizeWithoutMovingTheAnchor() {
        let frame = CGRect(x: 100, y: 80, width: 200, height: 100)
        let anchor = CGPoint(x: 160, y: 75)

        let scaled = PinResizeGeometry.scaledFrame(
            frame,
            requestedScale: 100,
            anchorInWindow: anchor,
            minimumSize: CGSize(width: 80, height: 40),
            maximumSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(scaled.size, CGSize(width: 400, height: 200))
        assertAnchorIsStable(oldFrame: frame, newFrame: scaled, anchor: anchor)
    }

    func testScalingClampsAtMinimumSizeAndPreservesAspectRatio() {
        let frame = CGRect(x: 100, y: 80, width: 200, height: 100)
        let anchor = CGPoint(x: 100, y: 50)

        let scaled = PinResizeGeometry.scaledFrame(
            frame,
            requestedScale: 0.01,
            anchorInWindow: anchor,
            minimumSize: CGSize(width: 150, height: 80),
            maximumSize: CGSize(width: 800, height: 400)
        )

        XCTAssertEqual(scaled.size, CGSize(width: 160, height: 80))
        XCTAssertEqual(scaled.width / scaled.height, frame.width / frame.height, accuracy: 0.001)
        assertAnchorIsStable(oldFrame: frame, newFrame: scaled, anchor: anchor)
    }

    func testInitialSizeLimitsAreFiniteAndContainTheInitialSize() {
        let initialSize = CGSize(width: 200, height: 120)

        let limits = PinResizeGeometry.sizeLimits(for: initialSize)

        XCTAssertLessThanOrEqual(limits.minimum.width, initialSize.width)
        XCTAssertLessThanOrEqual(limits.minimum.height, initialSize.height)
        XCTAssertGreaterThanOrEqual(limits.maximum.width, initialSize.width)
        XCTAssertGreaterThanOrEqual(limits.maximum.height, initialSize.height)
        XCTAssertLessThanOrEqual(limits.maximum.width, 8_192)
        XCTAssertLessThanOrEqual(limits.maximum.height, 8_192)
        XCTAssertEqual(limits.minimum.width / limits.minimum.height, initialSize.width / initialSize.height, accuracy: 0.001)
        XCTAssertEqual(limits.maximum.width / limits.maximum.height, initialSize.width / initialSize.height, accuracy: 0.001)
    }

    func testOnePixelImageCanGrowToAnOperableSize() {
        let limits = PinResizeGeometry.sizeLimits(for: CGSize(width: 1, height: 1))

        XCTAssertGreaterThanOrEqual(limits.maximum.width, 96)
        XCTAssertGreaterThanOrEqual(limits.maximum.height, 64)
        XCTAssertLessThanOrEqual(limits.maximum.width, 8_192)
        XCTAssertLessThanOrEqual(limits.maximum.height, 8_192)
        XCTAssertEqual(limits.maximum.width / limits.maximum.height, 1, accuracy: 0.001)
    }

    func testTinyImageStartsAtAnOperableSizeWhenScreenSpaceAllows() {
        XCTAssertEqual(
            PinResizeGeometry.operableInitialSize(
                CGSize(width: 1, height: 1),
                maximumSize: CGSize(width: 600, height: 400)
            ),
            CGSize(width: 96, height: 96)
        )
        XCTAssertEqual(
            PinResizeGeometry.operableInitialSize(
                CGSize(width: 240, height: 160),
                maximumSize: CGSize(width: 600, height: 400)
            ),
            CGSize(width: 240, height: 160)
        )
    }

    func testExtremelyWideImageUsesDimensionCapWhenShortEdgeCannotReachMinimum() {
        let limits = PinResizeGeometry.sizeLimits(for: CGSize(width: 1_000, height: 4))

        XCTAssertEqual(limits.maximum.width, 8_192, accuracy: 0.001)
        XCTAssertEqual(limits.maximum.height, 32.768, accuracy: 0.001)
        XCTAssertEqual(limits.maximum.width / limits.maximum.height, 250, accuracy: 0.001)
    }

    func testDraggedOriginKeepsAtLeastThirtyTwoPointsVisible() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let windowSize = CGSize(width: 200, height: 120)

        let pastLowerEdges = PinResizeGeometry.originKeepingWindowVisible(
            proposedOrigin: CGPoint(x: -500, y: -500),
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )
        let pastUpperEdges = PinResizeGeometry.originKeepingWindowVisible(
            proposedOrigin: CGPoint(x: 2_000, y: 2_000),
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(pastLowerEdges, CGPoint(x: -168, y: -88))
        XCTAssertEqual(pastUpperEdges, CGPoint(x: 968, y: 768))
    }

    private func assertAnchorIsStable(
        oldFrame: CGRect,
        newFrame: CGRect,
        anchor: CGPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scale = newFrame.width / oldFrame.width
        let oldGlobalAnchor = CGPoint(
            x: oldFrame.minX + anchor.x,
            y: oldFrame.minY + anchor.y
        )
        let newGlobalAnchor = CGPoint(
            x: newFrame.minX + anchor.x * scale,
            y: newFrame.minY + anchor.y * scale
        )
        XCTAssertEqual(newGlobalAnchor.x, oldGlobalAnchor.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(newGlobalAnchor.y, oldGlobalAnchor.y, accuracy: 0.001, file: file, line: line)
    }
}
