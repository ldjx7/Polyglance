import CoreGraphics
import XCTest
@testable import PolyglanceKit

final class CaptureGeometryTests: XCTestCase {
    func testSelectionNormalizesReverseDragAndClampsToBounds() {
        let selection = CaptureGeometry.selectionRect(
            from: CGPoint(x: 110, y: 70),
            to: CGPoint(x: 10, y: -5),
            in: CGRect(x: 0, y: 0, width: 100, height: 60)
        )

        XCTAssertEqual(selection, CGRect(x: 10, y: 0, width: 90, height: 60))
    }

    func testPixelCropConvertsScaleAndFlipsVerticalAxis() {
        let crop = CaptureGeometry.pixelCropRect(
            selection: CGRect(x: 10, y: 5, width: 30, height: 20),
            viewSize: CGSize(width: 100, height: 50),
            imagePixelSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(crop, CGRect(x: 20, y: 50, width: 60, height: 40))
    }

    func testOutputPixelSizeMatchesIntegralCropForFractionalNonUniformScale() {
        let selection = CGRect(x: 10.25, y: 20.25, width: 30.25, height: 15.25)
        let viewSize = CGSize(width: 100, height: 80)
        let imageSize = CGSize(width: 200, height: 240)

        let size = CaptureGeometry.outputPixelSize(
            selection: selection,
            viewSize: viewSize,
            imagePixelSize: imageSize
        )

        XCTAssertEqual(
            size,
            CaptureGeometry.pixelCropRect(
                selection: selection,
                viewSize: viewSize,
                imagePixelSize: imageSize
            ).size
        )
        XCTAssertEqual(size, CGSize(width: 61, height: 47))
    }

    func testSelectionMustHaveMeaningfulArea() {
        XCTAssertFalse(CaptureGeometry.isUsable(CGRect(x: 0, y: 0, width: 3, height: 20)))
        XCTAssertFalse(CaptureGeometry.isUsable(CGRect(x: 0, y: 0, width: 20, height: 3)))
        XCTAssertTrue(CaptureGeometry.isUsable(CGRect(x: 0, y: 0, width: 4, height: 4)))
    }

    func testPinSizePreservesAspectRatioWithinMaximum() {
        XCTAssertEqual(
            CaptureGeometry.fittedPinSize(
                imageSize: CGSize(width: 1200, height: 600),
                maximumSize: CGSize(width: 600, height: 400)
            ),
            CGSize(width: 600, height: 300)
        )
        XCTAssertEqual(
            CaptureGeometry.fittedPinSize(
                imageSize: CGSize(width: 240, height: 160),
                maximumSize: CGSize(width: 600, height: 400)
            ),
            CGSize(width: 240, height: 160)
        )
    }

    func testPreferredCapturePixelSizeUsesRetinaScaleWhenReportedSizeIsLogical() {
        let size = CaptureGeometry.preferredCapturePixelSize(
            screenPointSize: CGSize(width: 1728, height: 1117),
            backingScaleFactor: 2,
            reportedPixelSize: CGSize(width: 1728, height: 1117)
        )

        XCTAssertEqual(size, CGSize(width: 3456, height: 2234))
    }

    func testPreferredCapturePixelSizeKeepsLargerPhysicalDisplaySize() {
        let size = CaptureGeometry.preferredCapturePixelSize(
            screenPointSize: CGSize(width: 1920, height: 1080),
            backingScaleFactor: 1,
            reportedPixelSize: CGSize(width: 3840, height: 2160)
        )

        XCTAssertEqual(size, CGSize(width: 3840, height: 2160))
    }

    func testToolbarPlacementPrefersBelowAndClampsToScreen() {
        let origin = CaptureGeometry.toolbarOrigin(
            selection: CGRect(x: 280, y: 80, width: 40, height: 50),
            toolbarSize: CGSize(width: 140, height: 36),
            bounds: CGRect(x: 0, y: 0, width: 320, height: 200)
        )

        XCTAssertEqual(origin, CGPoint(x: 172, y: 36))
    }

    func testToolbarPlacementMovesAboveWhenThereIsNoRoomBelow() {
        let origin = CaptureGeometry.toolbarOrigin(
            selection: CGRect(x: 20, y: 10, width: 100, height: 40),
            toolbarSize: CGSize(width: 140, height: 36),
            bounds: CGRect(x: 0, y: 0, width: 320, height: 200)
        )

        XCTAssertEqual(origin, CGPoint(x: 8, y: 58))
    }

    func testToolbarPlacementMovesInsideSelectionAtBottomWhenThereIsNoRoomAboveOrBelow() {
        let origin = CaptureGeometry.toolbarOrigin(
            selection: CGRect(x: 20, y: 10, width: 100, height: 185),
            toolbarSize: CGSize(width: 140, height: 36),
            bounds: CGRect(x: 0, y: 0, width: 320, height: 200)
        )

        XCTAssertEqual(origin, CGPoint(x: 8, y: 18))
    }

    func testToolbarSizeFitsNarrowScreenWithoutChangingPreferredHeight() {
        XCTAssertEqual(
            CaptureGeometry.fittedToolbarSize(
                preferred: CGSize(width: 672, height: 44),
                bounds: CGRect(x: 0, y: 0, width: 640, height: 480)
            ),
            CGSize(width: 624, height: 44)
        )
        XCTAssertEqual(
            CaptureGeometry.fittedToolbarSize(
                preferred: CGSize(width: 672, height: 44),
                bounds: CGRect(x: 0, y: 0, width: 1_440, height: 900)
            ),
            CGSize(width: 672, height: 44)
        )
    }

    func testAnnotationPointMapsFromSelectionPointsToOutputPixels() {
        let point = CaptureGeometry.annotationPixelPoint(
            CGPoint(x: 15, y: 25),
            selection: CGRect(x: 10, y: 20, width: 20, height: 10),
            imagePixelSize: CGSize(width: 40, height: 20)
        )

        XCTAssertEqual(point, CGPoint(x: 10, y: 10))
    }

    func testSelectionEditTargetRecognizesHandlesAndInterior() {
        let selection = CGRect(x: 100, y: 80, width: 200, height: 120)

        XCTAssertEqual(
            CaptureGeometry.selectionEditTarget(at: CGPoint(x: 100, y: 200), selection: selection),
            .resize(.topLeft)
        )
        XCTAssertEqual(
            CaptureGeometry.selectionEditTarget(at: CGPoint(x: 300, y: 140), selection: selection),
            .resize(.right)
        )
        XCTAssertEqual(
            CaptureGeometry.selectionEditTarget(at: CGPoint(x: 180, y: 130), selection: selection),
            .move
        )
        XCTAssertNil(
            CaptureGeometry.selectionEditTarget(at: CGPoint(x: 30, y: 30), selection: selection)
        )
    }

    func testSelectionEditTargetChoosesNearestEdgeWhenHandlesOverlap() {
        let tinySelection = CGRect(x: 100, y: 80, width: 4, height: 40)

        XCTAssertEqual(
            CaptureGeometry.selectionEditTarget(
                at: CGPoint(x: tinySelection.maxX, y: tinySelection.midY),
                selection: tinySelection
            ),
            .resize(.right)
        )
        XCTAssertEqual(
            CaptureGeometry.selectionEditTarget(
                at: CGPoint(x: tinySelection.minX, y: tinySelection.midY),
                selection: tinySelection
            ),
            .resize(.left)
        )
    }

    func testSelectionExpansionTargetRecognizesAllEightOutsideDirections() {
        let selection = CGRect(x: 100, y: 80, width: 200, height: 120)
        let cases: [(CGPoint, CaptureSelectionEditTarget)] = [
            (CGPoint(x: 180, y: 240), .resize(.top)),
            (CGPoint(x: 180, y: 40), .resize(.bottom)),
            (CGPoint(x: 60, y: 140), .resize(.left)),
            (CGPoint(x: 340, y: 140), .resize(.right)),
            (CGPoint(x: 60, y: 240), .resize(.topLeft)),
            (CGPoint(x: 340, y: 240), .resize(.topRight)),
            (CGPoint(x: 60, y: 40), .resize(.bottomLeft)),
            (CGPoint(x: 340, y: 40), .resize(.bottomRight)),
        ]

        for (point, expectedTarget) in cases {
            XCTAssertEqual(
                CaptureGeometry.selectionExpansionTarget(at: point, selection: selection),
                expectedTarget,
                "Unexpected expansion direction for \(point)"
            )
        }
        XCTAssertNil(
            CaptureGeometry.selectionExpansionTarget(
                at: CGPoint(x: selection.midX, y: selection.midY),
                selection: selection
            )
        )
        XCTAssertEqual(
            CaptureGeometry.selectionExpansionTarget(
                at: CGPoint(x: selection.minX, y: selection.maxY + 20),
                selection: selection
            ),
            .resize(.top)
        )
        XCTAssertNil(
            CaptureGeometry.selectionExpansionTarget(
                at: CGPoint(x: selection.minX, y: selection.maxY),
                selection: selection
            )
        )
    }

    func testSelectionExpansionRejectsEmptyOrNullSelection() {
        XCTAssertNil(
            CaptureGeometry.selectionExpansionTarget(
                at: CGPoint(x: 10, y: 10),
                selection: .zero
            )
        )
        XCTAssertNil(
            CaptureGeometry.selectionExpansionTarget(
                at: CGPoint(x: 10, y: 10),
                selection: .null
            )
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                .zero,
                toward: CGPoint(x: 10, y: 10),
                target: .resize(.topRight),
                in: CGRect(x: 0, y: 0, width: 100, height: 100)
            ),
            .zero
        )
    }

    func testExpandedSelectionMovesOnlyEdgesFacingPointerAndClampsToBounds() {
        let selection = CGRect(x: 100, y: 80, width: 200, height: 120)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 180, y: 240),
                in: bounds
            ),
            CGRect(x: 100, y: 80, width: 200, height: 160)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 350, y: 240),
                in: bounds
            ),
            CGRect(x: 100, y: 80, width: 250, height: 160)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: -50, y: 500),
                in: bounds
            ),
            CGRect(x: 0, y: 80, width: 300, height: 220)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: selection.midX, y: selection.midY),
                in: bounds
            ),
            selection
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 20, y: selection.midY),
                in: bounds
            ),
            CGRect(x: 20, y: 80, width: 280, height: 120)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: selection.midX, y: 20),
                in: bounds
            ),
            CGRect(x: 100, y: 20, width: 200, height: 180)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 350, y: 20),
                in: bounds
            ),
            CGRect(x: 100, y: 20, width: 250, height: 180)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 20, y: 20),
                in: bounds
            ),
            CGRect(x: 20, y: 20, width: 280, height: 180)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 20, y: 240),
                in: bounds
            ),
            CGRect(x: 20, y: 80, width: 280, height: 160)
        )
        XCTAssertEqual(
            CaptureGeometry.expandedSelection(
                selection,
                toward: CGPoint(x: 20, y: selection.midY),
                target: .resize(.right),
                in: bounds
            ),
            selection
        )
    }

    func testMovingSelectionPreservesSizeAndClampsToBounds() {
        let moved = CaptureGeometry.editedSelection(
            original: CGRect(x: 100, y: 80, width: 200, height: 120),
            dragStart: CGPoint(x: 150, y: 120),
            current: CGPoint(x: 390, y: 290),
            target: .move,
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(moved, CGRect(x: 200, y: 180, width: 200, height: 120))
    }

    func testResizingSelectionFromCornerUpdatesBothEdges() {
        let resized = CaptureGeometry.editedSelection(
            original: CGRect(x: 100, y: 80, width: 200, height: 120),
            dragStart: CGPoint(x: 300, y: 200),
            current: CGPoint(x: 350, y: 240),
            target: .resize(.topRight),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400)
        )

        XCTAssertEqual(resized, CGRect(x: 100, y: 80, width: 250, height: 160))
    }

    func testResizingSelectionCannotCrossMinimumSize() {
        let resized = CaptureGeometry.editedSelection(
            original: CGRect(x: 100, y: 80, width: 200, height: 120),
            dragStart: CGPoint(x: 100, y: 140),
            current: CGPoint(x: 400, y: 140),
            target: .resize(.left),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            minimumSide: 4
        )

        XCTAssertEqual(resized, CGRect(x: 296, y: 80, width: 4, height: 120))
    }

    func testKeyboardStandardStepMovesSelectionOnePointInEveryDirection() {
        let selection = CGRect(x: 20, y: 30, width: 40, height: 20)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cases: [(CaptureSelectionKeyboardDirection, CGRect)] = [
            (.left, CGRect(x: 19, y: 30, width: 40, height: 20)),
            (.right, CGRect(x: 21, y: 30, width: 40, height: 20)),
            (.up, CGRect(x: 20, y: 31, width: 40, height: 20)),
            (.down, CGRect(x: 20, y: 29, width: 40, height: 20)),
        ]

        for (direction, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .move,
                        step: .standard
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Unexpected movement for \(direction)"
            )
        }
    }

    func testKeyboardAcceleratedMoveUsesTenPointsAndClampsToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 15, y: 70, width: 20, height: 10)

        XCTAssertEqual(
            CaptureGeometry.adjustedSelection(
                selection,
                by: CaptureSelectionKeyboardAdjustment(
                    direction: .left,
                    operation: .move,
                    step: .accelerated
                ),
                in: bounds
            ),
            CGRect(x: 5, y: 70, width: 20, height: 10)
        )
        XCTAssertEqual(
            CaptureGeometry.adjustedSelection(
                selection,
                by: CaptureSelectionKeyboardAdjustment(
                    direction: .up,
                    operation: .move,
                    step: .accelerated
                ),
                in: bounds
            ),
            CGRect(x: 15, y: 80, width: 20, height: 10)
        )
        XCTAssertEqual(
            CaptureGeometry.adjustedSelection(
                CGRect(x: 3, y: 85, width: 20, height: 10),
                by: CaptureSelectionKeyboardAdjustment(
                    direction: .left,
                    operation: .move,
                    step: .accelerated
                ),
                in: bounds
            ),
            CGRect(x: 0, y: 85, width: 20, height: 10)
        )
        XCTAssertEqual(
            CaptureGeometry.adjustedSelection(
                CGRect(x: 3, y: 85, width: 20, height: 10),
                by: CaptureSelectionKeyboardAdjustment(
                    direction: .up,
                    operation: .move,
                    step: .accelerated
                ),
                in: bounds
            ),
            CGRect(x: 3, y: 90, width: 20, height: 10)
        )
    }

    func testKeyboardAcceleratedStepCombinesWithEveryOperation() {
        let selection = CGRect(x: 50, y: 60, width: 40, height: 30)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let cases: [(CaptureSelectionKeyboardOperation, CGRect)] = [
            (.move, CGRect(x: 40, y: 60, width: 40, height: 30)),
            (.shrink, CGRect(x: 60, y: 60, width: 30, height: 30)),
            (.expand, CGRect(x: 40, y: 60, width: 50, height: 30)),
        ]

        for (operation, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: .left,
                        operation: operation,
                        step: .accelerated
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Accelerated step was not ten points for \(operation)"
            )
        }
    }

    func testKeyboardShrinkMovesOnlyTheCorrespondingEdgeInward() {
        let selection = CGRect(x: 20, y: 30, width: 40, height: 20)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cases: [(CaptureSelectionKeyboardDirection, CGRect)] = [
            (.left, CGRect(x: 21, y: 30, width: 39, height: 20)),
            (.right, CGRect(x: 20, y: 30, width: 39, height: 20)),
            (.up, CGRect(x: 20, y: 30, width: 40, height: 19)),
            (.down, CGRect(x: 20, y: 31, width: 40, height: 19)),
        ]

        for (direction, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .shrink,
                        step: .standard
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Unexpected inward edge movement for \(direction)"
            )
        }
    }

    func testKeyboardAcceleratedShrinkStopsAtOnePointMinimumSide() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let selection = CGRect(x: 20, y: 30, width: 6, height: 4)
        let cases: [(CaptureSelectionKeyboardDirection, CGRect)] = [
            (.left, CGRect(x: 25, y: 30, width: 1, height: 4)),
            (.right, CGRect(x: 20, y: 30, width: 1, height: 4)),
            (.up, CGRect(x: 20, y: 30, width: 6, height: 1)),
            (.down, CGRect(x: 20, y: 33, width: 6, height: 1)),
        ]

        for (direction, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .shrink,
                        step: .accelerated
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Accelerated shrink crossed the minimum side for \(direction)"
            )
        }
    }

    func testKeyboardShrinkCannotMakeOnePointSelectionEmpty() {
        let selection = CGRect(x: 20, y: 30, width: 1, height: 1)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)

        for direction in [
            CaptureSelectionKeyboardDirection.left,
            .right,
            .up,
            .down,
        ] {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .shrink,
                        step: .accelerated
                    ),
                    in: bounds
                ),
                selection,
                "One-point selection became empty for \(direction)"
            )
        }
    }

    func testKeyboardShrinkHonorsCustomMinimumSide() {
        XCTAssertEqual(
            CaptureGeometry.adjustedSelection(
                CGRect(x: 20, y: 30, width: 6, height: 10),
                by: CaptureSelectionKeyboardAdjustment(
                    direction: .right,
                    operation: .shrink,
                    step: .accelerated
                ),
                in: CGRect(x: 0, y: 0, width: 100, height: 100),
                minimumSide: 4
            ),
            CGRect(x: 20, y: 30, width: 4, height: 10)
        )
    }

    func testKeyboardExpandMovesOnlyTheCorrespondingEdgeOutward() {
        let selection = CGRect(x: 20, y: 30, width: 40, height: 20)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cases: [(CaptureSelectionKeyboardDirection, CGRect)] = [
            (.left, CGRect(x: 19, y: 30, width: 41, height: 20)),
            (.right, CGRect(x: 20, y: 30, width: 41, height: 20)),
            (.up, CGRect(x: 20, y: 30, width: 40, height: 21)),
            (.down, CGRect(x: 20, y: 29, width: 40, height: 21)),
        ]

        for (direction, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .expand,
                        step: .standard
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Unexpected outward edge movement for \(direction)"
            )
        }
    }

    func testKeyboardAcceleratedExpandClampsEachEdgeToBounds() {
        let selection = CGRect(x: 5, y: 3, width: 90, height: 94)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cases: [(CaptureSelectionKeyboardDirection, CGRect)] = [
            (.left, CGRect(x: 0, y: 3, width: 95, height: 94)),
            (.right, CGRect(x: 5, y: 3, width: 95, height: 94)),
            (.up, CGRect(x: 5, y: 3, width: 90, height: 97)),
            (.down, CGRect(x: 5, y: 0, width: 90, height: 97)),
        ]

        for (direction, expectedSelection) in cases {
            XCTAssertEqual(
                CaptureGeometry.adjustedSelection(
                    selection,
                    by: CaptureSelectionKeyboardAdjustment(
                        direction: direction,
                        operation: .expand,
                        step: .accelerated
                    ),
                    in: bounds
                ),
                expectedSelection,
                "Accelerated expansion crossed bounds for \(direction)"
            )
        }
    }

    func testKeyboardAdjustmentUsesOnePhysicalPixelOnRetinaDisplays() {
        let selection = CGRect(x: 20, y: 20, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)

        let moved = CaptureGeometry.adjustedSelection(
            selection,
            by: CaptureSelectionKeyboardAdjustment(
                direction: .right,
                operation: .move
            ),
            in: bounds,
            pixelsPerPoint: 2
        )
        let accelerated = CaptureGeometry.adjustedSelection(
            selection,
            by: CaptureSelectionKeyboardAdjustment(
                direction: .up,
                operation: .move,
                step: .accelerated
            ),
            in: bounds,
            pixelsPerPoint: 2
        )

        XCTAssertEqual(moved, CGRect(x: 20.5, y: 20, width: 200, height: 100))
        XCTAssertEqual(accelerated, CGRect(x: 20, y: 25, width: 200, height: 100))
    }

    func testKeyboardShrinkCanReachOnePhysicalPixelOnRetinaDisplays() {
        let selection = CGRect(x: 20, y: 20, width: 0.75, height: 10)

        let shrunk = CaptureGeometry.adjustedSelection(
            selection,
            by: CaptureSelectionKeyboardAdjustment(
                direction: .left,
                operation: .shrink
            ),
            in: CGRect(x: 0, y: 0, width: 100, height: 100),
            minimumSide: 0.5,
            pixelsPerPoint: 2
        )

        XCTAssertEqual(shrunk, CGRect(x: 20.25, y: 20, width: 0.5, height: 10))
    }
}
