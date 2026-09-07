import AppKit
import XCTest
@testable import Polyglance

@MainActor
final class PinSessionWindowTests: XCTestCase {
    func testRepeatedClipboardTraversesDistinctHistoryWithoutDuplicatingVisibleContent() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PinArchiveStore(directoryURL: dir)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: store)
        manager.pinText("较早原文")?.close()
        manager.pinText("最近原文")?.close()
        try await manager.pinNextClipboardContent(image: nil, text: "最近原文")
        XCTAssertEqual(manager.state.activePinCount, 1)
        try await manager.pinNextClipboardContent(image: nil, text: "最近原文")
        XCTAssertEqual(manager.state.activePinCount, 2)
        try await manager.pinNextClipboardContent(image: nil, text: "最近原文")
        XCTAssertEqual(manager.state.activePinCount, 2)
        await manager.waitForPendingOperations()
        XCTAssertEqual(store.list().count, 2)
        manager.closeAllPins()
        await manager.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    func testOnlyOneTextCannotBeRepeatedEvenBeforeArchiveWriteFinishes() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: PinArchiveStore(directoryURL: dir))
        try await manager.pinNextClipboardContent(image: nil, text: "只有一条")
        try await manager.pinNextClipboardContent(image: nil, text: "只有一条")
        XCTAssertEqual(manager.state.activePinCount, 1)
        manager.hideAllPins()
        try await manager.pinNextClipboardContent(image: nil, text: "只有一条")
        XCTAssertEqual(manager.state.activePinCount, 1)
        manager.closeAllPins()
        await manager.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    func testShortTextUsesCompactBorderlessCard() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: PinArchiveStore(directoryURL: dir))
        let panel = try XCTUnwrap(manager.pinText("销毁测试贴图后，历史中消失，关闭恢复和重启都不能让它再次出现。"))
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertLessThan(panel.frame.height, 80)
        XCTAssertGreaterThan(panel.frame.width, 500)
        XCTAssertTrue(panel.hasShadow)
        panel.close()
        await manager.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    func testTextMenuControlsStateWithoutDisablingTextSelection() throws {
        _ = NSApplication.shared
        var closed = false
        var destroyed = false
        var restored = false
        let panel = PinPanel(contentRect: CGRect(x: 120, y: 140, width: 400, height: 240),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = TextPinContentView(text: "选择文字", actions: PinWindowActions(
            close: { closed = true }, destroy: { destroyed = true }, restoreMostRecent: { restored = true }))
        panel.contentView = view
        let menu = try XCTUnwrap(view.makeContextMenu())
        func perform(_ title: String) throws {
            let currentMenu = view.makeContextMenu()
            let item = try XCTUnwrap(currentMenu.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        try perform("锁定贴图")
        XCTAssertTrue(view.isLocked)
        XCTAssertFalse(panel.isMovable)
        XCTAssertTrue(view.textView.isSelectable)
        try perform("解锁贴图")
        XCTAssertFalse(view.isLocked)
        XCTAssertTrue(panel.isMovable)
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        try perform("置顶贴图")
        XCTAssertEqual(panel.level, .floating)
        try perform("取消置顶")
        XCTAssertEqual(panel.level, .normal)
        let opacityMenu = try XCTUnwrap(view.makeContextMenu().items.first { $0.title == "透明度" }?.submenu)
        let eightyPercent = try XCTUnwrap(opacityMenu.items.first { $0.title == "80%" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(eightyPercent.action), to: eightyPercent.target, from: eightyPercent))
        XCTAssertEqual(panel.alphaValue, 0.8, accuracy: 0.001)
        let hundredPercent = try XCTUnwrap(opacityMenu.items.first { $0.title == "100%" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(hundredPercent.action), to: hundredPercent.target, from: hundredPercent))
        XCTAssertEqual(panel.alphaValue, 1)
        try perform("关闭贴图")
        try perform("彻底销毁贴图")
        try perform("恢复最近关闭的贴图")
        XCTAssertTrue(closed && destroyed && restored)
        panel.close()
    }
    func testTextCanCloseAndRestoreImmediatelyBeforeAsyncArchiveCompletes() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: PinArchiveStore(directoryURL: dir))
        let panel = try XCTUnwrap(manager.pinText("可选的原文"))
        manager.closePin(panel)
        let restored = try XCTUnwrap(manager.restoreMostRecentPin())
        XCTAssertEqual((restored.contentView as? TextPinContentView)?.textView.string, "可选的原文")
        restored.close()
        await manager.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    func testDestroyRemovesAllCopiesAndClosedRestoreReferences() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: store)
        let first = try XCTUnwrap(manager.pinText("需要销毁的原文"))
        await manager.waitForPendingOperations()
        let id = try XCTUnwrap(store.list().first?.id)
        first.close()
        let second = try XCTUnwrap(manager.pinText("需要销毁的原文", archiveID: id))
        manager.destroyPin(second)
        await manager.waitForPendingOperations()
        XCTAssertEqual(manager.state.activePinCount, 0)
        XCTAssertNil(manager.restoreMostRecentPin())
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(store.loadSessions().isEmpty)
        await manager.prepareForTermination()
    }

    func testRestartRestoresActiveTextGeometryButNotClosedPins() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PinArchiveStore(directoryURL: dir)
        let first = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: store)
        let active = try XCTUnwrap(first.pinText("保留原文\nsecond line"))
        let closed = try XCTUnwrap(first.pinText("已关闭"))
        closed.close()
        active.setFrame(CGRect(x: 150, y: 160, width: 410, height: 300), display: false)
        active.alphaValue = .init(0.6)
        await first.prepareForTermination()
        active.close()
        let second = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: PinArchiveStore(directoryURL: dir))
        await second.restoreSessionWindows()
        XCTAssertEqual(second.state.activePinCount, 1)
        XCTAssertEqual(second.state.historyCount, 1)
        let record = try XCTUnwrap(store.loadSessions().first { $0.status == .active })
        XCTAssertEqual(record.frame, CGRect(x: 150, y: 160, width: 410, height: 300))
        XCTAssertEqual(record.opacity, 0.6)
        XCTAssertNotNil(second.restoreMostRecentPin())
        second.closeAllPins()
        await second.prepareForTermination()
        try? FileManager.default.removeItem(at: dir)
    }

    func testTextPinClosesOnDoubleClick() throws {
        _ = NSApplication.shared
        var closed = false
        let view = TextPinContentView(
            text: "双击关闭测试",
            actions: PinWindowActions(close: { closed = true })
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        view.mouseDown(with: event)
        XCTAssertTrue(closed)

        closed = false
        view.textView.mouseDown(with: event)
        XCTAssertTrue(closed)
    }

    func testDestroyTextPinClearsMatchingPasteboard() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: store)
        let panel = try XCTUnwrap(manager.pinText("销毁同时清理剪贴板"))
        await manager.waitForPendingOperations()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("销毁同时清理剪贴板", forType: .string)

        manager.destroyPin(panel)
        await manager.waitForPendingOperations()

        XCTAssertNil(NSPasteboard.general.string(forType: .string))
        await manager.prepareForTermination()
    }

    func testPinNextClipboardContentDoesNothingWhenEmpty() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PinArchiveStore(directoryURL: dir)
        let manager = PinWindowManager(historyStore: PinHistoryStore(), archiveStore: store)
        NSPasteboard.general.clearContents()
        try manager.pinClipboardImage()
        try await manager.pinNextClipboardContent(image: nil, text: nil)
        XCTAssertEqual(manager.state.activePinCount, 0)
        await manager.prepareForTermination()
    }

    func testTextPinSupportsWheelZoomAndShowsPercentage() throws {
        _ = NSApplication.shared
        let view = TextPinContentView(
            text: "缩放测试文本",
            actions: PinWindowActions()
        )
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: view.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        let oldWidth = panel.frame.width

        view.applyScroll(deltaY: 5, modifiers: [], anchorInWindow: CGPoint(x: 50, y: 30))
        XCTAssertGreaterThan(panel.frame.width, oldWidth)

        let indicator = try XCTUnwrap(view.subviews.compactMap { $0 as? PinZoomIndicatorView }.first)
        XCTAssertFalse(indicator.isHidden)
    }
}
