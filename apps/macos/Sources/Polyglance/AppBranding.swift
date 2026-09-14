import AppKit

@MainActor
enum PolyglanceMenuBarIcon {
    static let image: NSImage = {
        let size = CGSize(width: 18, height: 18)
        let icon = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            let cropPath = NSBezierPath()
            cropPath.lineWidth = 1.4
            cropPath.lineCapStyle = .round
            cropPath.lineJoinStyle = .round
            let minimum: CGFloat = 1
            let maximum: CGFloat = 17
            let arm: CGFloat = 3.2
            for points in [
                [CGPoint(x: minimum, y: minimum + arm), CGPoint(x: minimum, y: minimum), CGPoint(x: minimum + arm, y: minimum)],
                [CGPoint(x: maximum - arm, y: minimum), CGPoint(x: maximum, y: minimum), CGPoint(x: maximum, y: minimum + arm)],
                [CGPoint(x: minimum, y: maximum - arm), CGPoint(x: minimum, y: maximum), CGPoint(x: minimum + arm, y: maximum)],
                [CGPoint(x: maximum - arm, y: maximum), CGPoint(x: maximum, y: maximum), CGPoint(x: maximum, y: maximum - arm)],
            ] {
                cropPath.move(to: points[0])
                cropPath.line(to: points[1])
                cropPath.line(to: points[2])
            }
            cropPath.stroke()

            // 保留与彩色 Logo 一致的前后双语卡片，留白由系统背景透出。
            let rearCard = NSBezierPath(roundedRect: NSRect(x: 7.5, y: 6.3, width: 7.6, height: 8.5),
                                        xRadius: 1.3, yRadius: 1.3)
            rearCard.lineWidth = 0.8
            rearCard.stroke()

            func drawGlyph(_ glyph: String, center: CGPoint, fontSize: CGFloat) {
                let text = glyph as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
                    .foregroundColor: NSColor.black,
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: center.x - textSize.width / 2,
                                     y: center.y - textSize.height / 2),
                          withAttributes: attributes)
            }
            drawGlyph("文", center: CGPoint(x: 12.4, y: 11), fontSize: 5.2)

            let frontCard = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 7.2, height: 8.5),
                                         xRadius: 1.3, yRadius: 1.3)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            frontCard.fill()
            NSGraphicsContext.restoreGraphicsState()
            frontCard.lineWidth = 0.8
            frontCard.stroke()
            drawGlyph("A", center: CGPoint(x: 6.6, y: 7.4), fontSize: 7)
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Polyglance"
        return icon
    }()
}

@MainActor
enum AppVersionInfo {
    static func versionString(infoDictionary: [String: Any]?) -> String {
        var version = (infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.5")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if version.lowercased().hasPrefix("polyglance ") {
            version.removeFirst("Polyglance ".count)
        }
        if version.lowercased().hasPrefix("v") {
            version.removeFirst()
        }
        version = String(version.split(separator: "+", maxSplits: 1).first ?? "")
        return version.isEmpty ? "0.0.5" : version
    }

    static var versionString: String {
        versionString(infoDictionary: Bundle.main.infoDictionary)
    }

    static func displayString(infoDictionary: [String: Any]?) -> String {
        "v\(versionString(infoDictionary: infoDictionary))"
    }

    static var displayString: String {
        displayString(infoDictionary: Bundle.main.infoDictionary)
    }
}
