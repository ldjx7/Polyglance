import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class ScreenRecordingOverlayTests: XCTestCase {
    func testOverlayStartsReadyBlueAndLocksRegionOnlyAfterRecordingStarts() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let region = CGRect(
            x: screen.frame.minX + 80,
            y: screen.frame.minY + 80,
            width: min(360, screen.frame.width - 160),
            height: min(220, screen.frame.height - 160)
        )
        let session = ScreenRecordingOverlaySession(
            region: region,
            screen: screen,
            settings: .default
        )

        session.present()
        defer { session.close() }

        XCTAssertEqual(session.state, .ready)
        XCTAssertTrue(session.isRegionEditable)
        XCTAssertEqual(session.borderColor, .systemBlue)
        XCTAssertTrue(session.toolbarPanel.isVisible)

        session.update(state: .recording)
        XCTAssertFalse(session.isRegionEditable)
        XCTAssertEqual(session.borderColor, .systemRed)

        session.update(state: .paused)
        XCTAssertFalse(session.isRegionEditable)
        XCTAssertEqual(session.borderColor, .systemOrange)
    }

    func testOverlayToolbarEmitsStartPauseStopCloseAndSettingsChanges() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let session = ScreenRecordingOverlaySession(
            region: CGRect(x: screen.frame.minX + 100, y: screen.frame.minY + 100, width: 320, height: 200),
            screen: screen,
            settings: .default
        )
        var actions: [ScreenRecordingOverlayAction] = []
        var changedSettings: RecordingSettings?
        session.onAction = { actions.append($0) }
        session.onSettingsChanged = { changedSettings = $0 }

        session.toolbarView.startButton.performClick(nil)
        session.update(state: .recording)
        session.toolbarView.pauseResumeButton.performClick(nil)
        session.toolbarView.stopButton.performClick(nil)
        session.toolbarView.closeButton.performClick(nil)

        XCTAssertEqual(actions, [.start, .pauseOrResume, .stop, .close])

        session.update(state: .ready)
        session.toolbarView.delayPopUp.selectItem(at: 2)
        session.toolbarView.applyCurrentSettingsSelection()
        XCTAssertEqual(changedSettings?.countdownDelay, .fiveSeconds)

        session.toolbarView.frameRatePopUp.selectItem(withTag: 60)
        session.toolbarView.applyCurrentSettingsSelection()
        XCTAssertEqual(changedSettings?.frameRate, 60)
    }

    func testToolbarUsesIconButtonsAndVisibleInWindowHoverHelp() throws {
        _ = NSApplication.shared
        let toolbar = ScreenRecordingToolbarView(settings: .default)
        let buttons: [NSButton] = [
            try XCTUnwrap(toolbar.systemAudioButton),
            try XCTUnwrap(toolbar.microphoneButton),
            try XCTUnwrap(toolbar.cursorButton),
            try XCTUnwrap(toolbar.startButton),
            try XCTUnwrap(toolbar.pauseResumeButton),
            try XCTUnwrap(toolbar.stopButton),
            try XCTUnwrap(toolbar.closeButton),
        ]

        for button in buttons {
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
            XCTAssertFalse(button.toolTip?.isEmpty ?? true)
            XCTAssertFalse(button.accessibilityLabel()?.isEmpty ?? true)
        }

        let start = try XCTUnwrap(toolbar.startButton as? ScreenRecordingToolbarButton)
        start.mouseEntered(with: mouseEvent(.mouseMoved))
        XCTAssertEqual(toolbar.visibleHelpText, start.toolTip)
        XCTAssertFalse(toolbar.helpBubble.isHidden)
        XCTAssertNil(toolbar.helpBubble.hitTest(.zero))
        start.mouseExited(with: mouseEvent(.mouseMoved))
        XCTAssertNil(toolbar.visibleHelpText)
    }

    func testToolbarExposesExplicitPixPinFrameRatesAndCurrentEffectiveValue() {
        _ = NSApplication.shared
        var settings = RecordingSettings.default
        settings.frameRate = 60
        let toolbar = ScreenRecordingToolbarView(settings: settings)

        XCTAssertEqual(toolbar.frameRatePopUp.itemArray.map(\.tag), [5, 16, 24, 30, 60])
        XCTAssertEqual(toolbar.frameRatePopUp.selectedTag(), 60)
        XCTAssertEqual(toolbar.frameRatePopUp.titleOfSelectedItem, "60 FPS")
    }

    func testToolbarCountdownAndRecordingStatesExposeCorrectActions() {
        _ = NSApplication.shared
        let toolbar = ScreenRecordingToolbarView(settings: .default)

        toolbar.update(state: .countingDown(remaining: 3))
        XCTAssertEqual(toolbar.statusLabel.stringValue, "3")
        XCTAssertTrue(toolbar.closeButton.isEnabled)
        XCTAssertFalse(toolbar.startButton.isEnabled)

        toolbar.update(state: .recording)
        XCTAssertTrue(toolbar.pauseResumeButton.isEnabled)
        XCTAssertTrue(toolbar.stopButton.isEnabled)

        toolbar.update(state: .paused)
        XCTAssertEqual(toolbar.pauseResumeButton.toolTip, "继续录制")
        XCTAssertTrue(toolbar.stopButton.isEnabled)

        toolbar.update(state: .finalizing)
        XCTAssertFalse(toolbar.pauseResumeButton.isEnabled)
        XCTAssertFalse(toolbar.stopButton.isEnabled)
    }

    func testReviewViewEmitsPlaybackSaveCopyRestartAndCloseActions() {
        _ = NSApplication.shared
        let view = ScreenRecordingReviewView(format: .mp4)
        var actions: [ScreenRecordingReviewAction] = []
        view.onAction = { actions.append($0) }

        view.playPauseButton.performClick(nil)
        view.saveButton.performClick(nil)
        view.quickSaveButton.performClick(nil)
        view.copyButton.performClick(nil)
        view.restartButton.performClick(nil)
        view.closeButton.performClick(nil)

        XCTAssertEqual(actions, [.playPause, .save, .quickSave, .copy, .restart, .close])
    }

    func testGIFReviewPreviewsWithoutOfferingFakePlaybackControl() {
        _ = NSApplication.shared

        let view = ScreenRecordingReviewView(format: .gif)

        XCTAssertFalse(view.playPauseButton.isEnabled)
        XCTAssertEqual(view.playPauseButton.toolTip, view.playPauseButton.title)
        XCTAssertEqual(view.playPauseButton.accessibilityHelp(), view.playPauseButton.title)
    }

    func testReviewSessionCanPresentGIFAndRetainsPanelUntilExplicitClose() throws {
        _ = NSApplication.shared
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Review-\(UUID().uuidString).gif")
        try Data().write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let session = ScreenRecordingReviewSession(outputURL: temporaryURL, format: .gif)

        session.present()
        XCTAssertTrue(session.panel.isVisible)
        XCTAssertEqual(session.format, .gif)
        session.close()
        XCTAssertFalse(session.panel.isVisible)
    }

    private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }
}
