import Foundation

enum PinSessionStatus: String, Codable, Sendable { case active, closed, archived }

/// One window instance. Multiple windows may refer to the same archive content.
struct PinSessionRecord: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var archiveID: String
    var text: String? = nil
    var frame: CGRect
    var opacity: Double = 1
    var isLocked = false
    var isAlwaysOnTop = true
    var status: PinSessionStatus = .active

    var isValid: Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0 && frame.width <= 32_768 && frame.height <= 32_768
            && opacity.isFinite && opacity >= 0.1 && opacity <= 1
            && (text?.utf8.count ?? 0) <= 1_048_576
    }
}
