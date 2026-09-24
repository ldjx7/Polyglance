import AVFoundation
import Foundation

enum MicrophonePermission {
    #if DEBUG
    static var mockStatus: AVAuthorizationStatus?
    #endif

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    static var authorizationStatus: AVAuthorizationStatus {
        #if DEBUG
        if let mockStatus { return mockStatus }
        #endif
        if isRunningTests {
            return .authorized
        }
        return AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestAccess() async -> Bool {
        #if DEBUG
        if let mockStatus { return mockStatus == .authorized }
        #endif
        if isRunningTests {
            return true
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestAccess(completionHandler: @escaping (Bool) -> Void) {
        #if DEBUG
        if let mockStatus {
            completionHandler(mockStatus == .authorized)
            return
        }
        #endif
        if isRunningTests {
            completionHandler(true)
            return
        }
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completionHandler)
    }
}
