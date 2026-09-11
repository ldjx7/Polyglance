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

        let containing = windows.filter { $0.frame.contains(quartzPoint) }
        if let best = containing.min(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }),
           let local = localRect(for: best.frame) {
            return local
        }

        return localDisplayBounds
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
        let containing = windows.filter { $0.frame.contains(quartzPoint) }
        let targetPID = containing.min(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })?.ownerPID ?? 0

        if let elementFrame = elementFrameLookup(targetPID, quartzPoint),
           elementFrame.contains(quartzPoint),
           let localElementFrame = localRect(for: elementFrame),
           localElementFrame.width >= 4,
           localElementFrame.height >= 4,
           (localElementFrame.width < localDisplayBounds.width - 6 || localElementFrame.height < localDisplayBounds.height - 6) {
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
        ownerPID: pid_t?,
        quartzPoint: CGPoint
    ) -> CGRect? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        // Try system-wide accessibility first to find leaf controls
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.06)
        var systemElement: AXUIElement?
        if AXUIElementCopyElementAtPosition(
            systemWide,
            Float(quartzPoint.x),
            Float(quartzPoint.y),
            &systemElement
        ) == .success,
        let systemElement {
            AXUIElementSetMessagingTimeout(systemElement, 0.06)
            if let pos = pointAttribute(kAXPositionAttribute as CFString, of: systemElement),
               let size = sizeAttribute(kAXSizeAttribute as CFString, of: systemElement),
               size.width >= 8, size.height >= 8 {
                let frame = CGRect(origin: pos, size: size)
                if frame.contains(quartzPoint) {
                    return frame
                }
            }
        }

        // Fall back to application-specific element lookup
        if let ownerPID, ownerPID > 0 {
            let application = AXUIElementCreateApplication(ownerPID)
            AXUIElementSetMessagingTimeout(application, 0.06)
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(
                application,
                Float(quartzPoint.x),
                Float(quartzPoint.y),
                &element
            ) == .success,
            let element {
                AXUIElementSetMessagingTimeout(element, 0.06)
                if let position = pointAttribute(kAXPositionAttribute as CFString, of: element),
                   let size = sizeAttribute(kAXSizeAttribute as CFString, of: element),
                   size.width >= 8, size.height >= 8 {
                    let frame = CGRect(origin: position, size: size)
                    if frame.contains(quartzPoint) {
                        return frame
                    }
                }
            }
        }

        return nil
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
