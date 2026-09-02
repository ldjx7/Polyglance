import AppKit

@MainActor
enum PolyglanceMenuBarIcon {
    static let image: NSImage = {
        let size = CGSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()

            let cropPath = NSBezierPath()
            cropPath.lineWidth = 1.7
            cropPath.lineCapStyle = .round
            cropPath.lineJoinStyle = .round
            let minimum: CGFloat = 2
            let maximum: CGFloat = 16
            let arm: CGFloat = 4.5
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

            let translationPath = NSBezierPath()
            translationPath.lineWidth = 1.7
            translationPath.lineCapStyle = .round
            translationPath.lineJoinStyle = .round
            translationPath.move(to: CGPoint(x: 5, y: 10.7))
            translationPath.line(to: CGPoint(x: 12.5, y: 10.7))
            translationPath.move(to: CGPoint(x: 10.2, y: 13))
            translationPath.line(to: CGPoint(x: 12.5, y: 10.7))
            translationPath.line(to: CGPoint(x: 10.2, y: 8.4))
            translationPath.move(to: CGPoint(x: 13, y: 6.5))
            translationPath.line(to: CGPoint(x: 5.5, y: 6.5))
            translationPath.move(to: CGPoint(x: 7.8, y: 4.2))
            translationPath.line(to: CGPoint(x: 5.5, y: 6.5))
            translationPath.line(to: CGPoint(x: 7.8, y: 8.8))
            translationPath.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Polyglance"
        return image
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
