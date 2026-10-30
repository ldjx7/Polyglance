import CoreGraphics
import Foundation

struct OCRDiagnostics: Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var activeRequests = 0

        func changeActiveRequests(by delta: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            activeRequests += delta
            return activeRequests
        }
    }

    private static let state = State()
    let id = UUID().uuidString
    let source: String
    private let startedAt = ProcessInfo.processInfo.systemUptime

    func begin() {
        let process = ProcessInfo.processInfo
        record("begin", [
            "activeRequests": Self.state.changeActiveRequests(by: 1),
            "os": process.operatingSystemVersionString,
            "systemUptime": process.systemUptime,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "thermalState": process.thermalState.rawValue,
        ])
    }

    func end() {
        record("end", ["activeRequests": Self.state.changeActiveRequests(by: -1)])
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        var payload = fields
        payload["event"] = event
        payload["id"] = id
        payload["source"] = source
        payload["pid"] = ProcessInfo.processInfo.processIdentifier
        payload["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let message = String(data: data, encoding: .utf8) else { return }
        PerfLogger.log("[OCR] \(message)")
    }

    func recordImage(_ image: CGImage) {
        record("input.cgimage", [
            "width": image.width,
            "height": image.height,
            "bitsPerComponent": image.bitsPerComponent,
            "bitsPerPixel": image.bitsPerPixel,
            "bytesPerRow": image.bytesPerRow,
            "bitmapInfo": image.bitmapInfo.rawValue,
            "alphaInfo": image.alphaInfo.rawValue,
            "colorSpace": image.colorSpace?.name.map { $0 as String } ?? "unknown",
            "colorSpaceModel": image.colorSpace?.model.rawValue ?? -1,
            "isMask": image.isMask,
        ])
    }

    func recordError(_ error: Error, stage: String) {
        recordError(error, stage: stage, depth: 0)
    }

    private func recordError(_ error: Error, stage: String, depth: Int) {
        let nsError = error as NSError
        record("error", [
            "stage": stage,
            "depth": depth,
            "type": String(reflecting: type(of: error)),
            "domain": nsError.domain,
            "code": nsError.code,
            "description": nsError.localizedDescription,
            "debug": String(reflecting: error),
            "failureReason": nsError.localizedFailureReason ?? "",
            "recoverySuggestion": nsError.localizedRecoverySuggestion ?? "",
            "userInfoKeys": nsError.userInfo.keys.sorted(),
        ])
        guard depth < 5 else { return }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            recordError(underlying, stage: stage + ".underlying", depth: depth + 1)
        }
        if let errors = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            for (index, underlying) in errors.prefix(8).enumerated() {
                recordError(underlying, stage: stage + ".underlying[\(index)]", depth: depth + 1)
            }
        }
    }
}
