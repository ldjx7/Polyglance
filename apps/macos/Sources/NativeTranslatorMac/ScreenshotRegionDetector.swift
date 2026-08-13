import AppKit
import ApplicationServices
import CoreGraphics

struct ScreenshotWindowRegion: Equatable {
    let frame: CGRect
    let ownerPID: pid_t
}

struct ScreenshotRegionDetector: @unchecked Sendable {
    typealias ElementFrameLookup = @Sendable (
        _ ownerPID: pid_t,
        _ quartzPoint: CGPoint
    ) -> CGRect?

    private let displayBounds: CGRect
    private let windows: [ScreenshotWindowRegion]
    private let elementFrameLookup: ElementFrameLookup

    init(
        displayBounds: CGRect,
        windows: [ScreenshotWindowRegion],
        elementFrameLookup: @escaping ElementFrameLookup
    ) {
        self.displayBounds = displayBounds
        self.windows = windows
        self.elementFrameLookup = elementFrameLookup
    }

    static func capture(for screen: NSScreen) -> ScreenshotRegionDetector? {
        guard let displayNumber = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(displayNumber.uint32Value)
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let windows = windowInfo.compactMap { info -> ScreenshotWindowRegion? in
            guard let ownerNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                  ownerNumber.int32Value != ownPID,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  acceptsWindowLayer(layerNumber.intValue),
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary),
                  frame.width >= 4,
                  frame.height >= 4,
                  frame.intersects(displayBounds) else {
                return nil
            }
            if let alphaNumber = info[kCGWindowAlpha as String] as? NSNumber,
               alphaNumber.doubleValue <= 0 {
                return nil
            }
            return ScreenshotWindowRegion(
                frame: frame,
                ownerPID: ownerNumber.int32Value
            )
        }

        return ScreenshotRegionDetector(
            displayBounds: displayBounds,
            windows: windows,
            elementFrameLookup: { ownerPID, quartzPoint in
                accessibilityElementFrame(ownerPID: ownerPID, quartzPoint: quartzPoint)
            }
        )
    }

    static func acceptsWindowLayer(_ layer: Int) -> Bool {
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        let floatingLevel = Int(CGWindowLevelForKey(.floatingWindow))
        return layer >= normalLevel && layer <= floatingLevel
    }

    func windowRegion(at localPoint: CGPoint) -> CGRect? {
        let localDisplayBounds = CGRect(origin: .zero, size: displayBounds.size)
        guard localDisplayBounds.contains(localPoint) else {
            return nil
        }

        let quartzPoint = CGPoint(
            x: displayBounds.minX + localPoint.x,
            y: displayBounds.maxY - localPoint.y
        )
        guard let window = windows.first(where: { $0.frame.contains(quartzPoint) }) else {
            return localDisplayBounds
        }

        return localRect(for: window.frame)
    }

    func refinedElementRegion(at localPoint: CGPoint) -> CGRect? {
        let localDisplayBounds = CGRect(origin: .zero, size: displayBounds.size)
        guard localDisplayBounds.contains(localPoint) else {
            return nil
        }

        let quartzPoint = CGPoint(
            x: displayBounds.minX + localPoint.x,
            y: displayBounds.maxY - localPoint.y
        )
        guard let window = windows.first(where: { $0.frame.contains(quartzPoint) }) else {
            return nil
        }

        if let elementFrame = elementFrameLookup(window.ownerPID, quartzPoint),
           elementFrame.contains(quartzPoint),
           let localElementFrame = localRect(for: elementFrame),
           localElementFrame.width >= 4,
           localElementFrame.height >= 4 {
            return localElementFrame
        }
        return nil
    }

    private func localRect(for quartzFrame: CGRect) -> CGRect? {
        let clippedFrame = quartzFrame.standardized.intersection(displayBounds)
        guard !clippedFrame.isNull else {
            return nil
        }
        return CGRect(
            x: clippedFrame.minX - displayBounds.minX,
            y: displayBounds.maxY - clippedFrame.maxY,
            width: clippedFrame.width,
            height: clippedFrame.height
        )
    }

    private static func accessibilityElementFrame(
        ownerPID: pid_t,
        quartzPoint: CGPoint
    ) -> CGRect? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let application = AXUIElementCreateApplication(ownerPID)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &element
        ) == .success,
        let element else {
            return nil
        }

        guard let position = pointAttribute(kAXPositionAttribute as CFString, of: element),
              let size = sizeAttribute(kAXSizeAttribute as CFString, of: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ attribute: CFString, of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ attribute: CFString, of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return size
    }
}
