import CoreGraphics
import Foundation

/// A decoded barcode and where it sits in the image.
///
/// `boundingBox` follows the project's OCR convention: normalized to 0...1 with
/// the origin at the lower left, which is exactly what Vision returns. Keeping
/// that space lets barcode frames reuse the same drawing code as OCR text boxes
/// instead of introducing a second convention.
struct BarcodeObservation: Equatable, @unchecked Sendable {
    let payload: String
    let symbology: BarcodeSymbology
    let boundingBox: CGRect
    /// Visual top-left, top-right, bottom-right, bottom-left. Coordinates use
    /// the same normalized lower-left space as `boundingBox`.
    let corners: [CGPoint]?

    init(
        payload: String,
        symbology: BarcodeSymbology,
        boundingBox: CGRect,
        corners: [CGPoint]? = nil
    ) {
        self.payload = payload
        self.symbology = symbology
        self.boundingBox = boundingBox
        self.corners = corners
    }

    var content: BarcodeContent {
        BarcodeContent(payload: payload)
    }
}

/// QR codes and the industrial symbologies the same detectors give us for free.
///
/// Symbologies the platform cannot detect are still listed when the other
/// platform reads them, so both ends report the same vocabulary.
enum BarcodeSymbology: String, Equatable, Sendable, CaseIterable {
    case qr
    case aztec
    case code128
    case code39
    case ean13
    case upca
    case dataMatrix
    case pdf417
    case other

    var title: String {
        switch self {
        case .qr: return "二维码"
        case .aztec: return "Aztec"
        case .code128: return "Code 128"
        case .code39: return "Code 39"
        case .ean13: return "EAN-13"
        case .upca: return "UPC-A"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        case .other: return "条码"
        }
    }
}

/// What a decoded payload actually means, so the UI can offer the right action.
///
/// The classification order matters: the network-specific schemes are matched
/// before the generic text fallback, and anything that is not plain web content
/// deliberately gets no "open" action.
enum BarcodeContent: Equatable, Sendable {
    case url(URL)
    case otp(URL)
    case wifi(ssid: String, password: String?, security: String?)
    case text(String)

    init(payload: String) {
        let normalized = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: normalized), let scheme = url.scheme?.lowercased() {
            if scheme == Self.otpScheme {
                self = .otp(url)
                return
            }
            // Only http(s) is openable. `file:`, `smb:` and custom schemes fall
            // through to text so they never get an "open" button.
            if scheme == "http" || scheme == "https" {
                self = .url(url)
                return
            }
        }
        if let wifi = Self.wifi(from: normalized) {
            self = wifi
            return
        }
        self = .text(payload)
    }

    private static let otpScheme = "otpauth"
    private static let wifiPrefix = "WIFI:"

    /// A barcode is a common phishing vector, so only plain web links may be
    /// opened, and even then the caller must show the full URL first.
    var isOpenable: Bool {
        if case .url = self {
            return true
        }
        return false
    }

    var copiedText: String {
        switch self {
        case let .url(url), let .otp(url):
            return url.absoluteString
        case let .wifi(_, password, _):
            return password ?? ""
        case let .text(text):
            return text
        }
    }

    /// QR results intentionally stay a lightweight copy/open workflow. Text
    /// translation belongs to OCR and screenshot translation, where the user
    /// explicitly asks for language processing.
    var isTranslatable: Bool {
        false
    }

    private static func wifi(from payload: String) -> BarcodeContent? {
        guard payload.prefix(wifiPrefix.count).caseInsensitiveCompare(wifiPrefix) == .orderedSame else {
            return nil
        }
        let fields = wifiFields(in: String(payload.dropFirst(wifiPrefix.count)))
        guard let ssid = fields["S"], !ssid.isEmpty else {
            return nil
        }
        return .wifi(ssid: ssid, password: fields["P"], security: fields["T"])
    }

    /// Splits on unescaped `;` and unescapes each value.
    ///
    /// WiFi payloads escape `,` `;` `:` and `\` with a backslash, so splitting on
    /// `;` naively cuts passwords in half.
    private static func wifiFields(in body: String) -> [String: String] {
        var fields: [String: String] = [:]
        var current = ""
        var isEscaping = false

        func commit() {
            defer { current = "" }
            guard let colon = current.firstIndex(of: ":") else {
                return
            }
            let key = String(current[..<colon]).uppercased()
            let value = String(current[current.index(after: colon)...])
            fields[key] = unescape(value)
        }

        for character in body {
            if isEscaping {
                current.append(character)
                isEscaping = false
            } else if character == "\\" {
                // Kept in place so `commit` can unescape the value as a whole.
                current.append(character)
                isEscaping = true
            } else if character == ";" {
                commit()
            } else {
                current.append(character)
            }
        }
        commit()
        return fields
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() {
                    if ["\\", ";", ":", ",", "\""].contains(next) {
                        result.append(next)
                    } else {
                        result.append("\\")
                        result.append(next)
                    }
                } else {
                    result.append("\\")
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
}
