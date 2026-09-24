import AVFoundation
import Foundation

enum ScreenRecordingAudioMixdownPolicy {
    static func shouldMix(
        format: ScreenRecordingFormat,
        capturesSystemAudio: Bool,
        capturesMicrophone: Bool
    ) -> Bool {
        format == .mp4 && capturesSystemAudio && capturesMicrophone
    }
}

enum ScreenRecordingAudioMixdown {
    static func mixIfNeeded(
        sourceURL: URL,
        options: ScreenRecordingOptions,
        fileManager: FileManager = .default
    ) async throws -> URL {
        try Task.checkCancellation()
        guard ScreenRecordingAudioMixdownPolicy.shouldMix(
            format: options.format,
            capturesSystemAudio: options.capturesSystemAudio,
            capturesMicrophone: options.capturesMicrophone
        ) else {
            return sourceURL
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        let audioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
        guard audioTracks.count > 1 else {
            return sourceURL
        }
        let duration = try await sourceAsset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        // Mix only the audio. Exporting the whole recording with HighestQuality
        // can encode the video a second time after capture has already finished.
        let audioComposition = AVMutableComposition()
        audioComposition.insertEmptyTimeRange(timeRange)

        var inputParameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudioTrack in audioTracks {
            guard let destinationTrack = audioComposition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ScreenRecordingAudioMixdownError.trackCreationFailed("音频")
            }
            try await insertTrack(sourceAudioTrack, into: destinationTrack, within: timeRange)
            let parameters = AVMutableAudioMixInputParameters(track: destinationTrack)
            parameters.setVolume(1, at: .zero)
            inputParameters.append(parameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        guard let audioExporter = AVAssetExportSession(
            asset: audioComposition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ScreenRecordingAudioMixdownError.exporterUnavailable
        }
        audioExporter.audioMix = audioMix
        audioExporter.timeRange = timeRange

        let mixedAudioURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".\(sourceURL.deletingPathExtension().lastPathComponent)-audio-\(UUID().uuidString).m4a"
        )
        let mixedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".\(sourceURL.deletingPathExtension().lastPathComponent)-mixed-\(UUID().uuidString).mp4"
        )
        defer {
            try? fileManager.removeItem(at: mixedAudioURL)
            try? fileManager.removeItem(at: mixedURL)
        }
        try await export(audioExporter, to: mixedAudioURL, as: .m4a)

        // Passthrough preserves the captured H.264 samples and frame timing.
        // The audio is already mixed, so no audioMix is applied to this export.
        let composition = AVMutableComposition()
        for sourceVideoTrack in try await sourceAsset.loadTracks(withMediaType: .video) {
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ScreenRecordingAudioMixdownError.trackCreationFailed("视频")
            }
            try await insertTrack(sourceVideoTrack, into: destinationTrack, within: timeRange)
            destinationTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        }
        let mixedAudioAsset = AVURLAsset(url: mixedAudioURL)
        guard let mixedAudioTrack = try await mixedAudioAsset.loadTracks(withMediaType: .audio).first,
              let destinationAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ScreenRecordingAudioMixdownError.trackCreationFailed("音频")
        }
        try await insertTrack(mixedAudioTrack, into: destinationAudioTrack, within: timeRange)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ScreenRecordingAudioMixdownError.exporterUnavailable
        }
        exporter.timeRange = timeRange
        exporter.shouldOptimizeForNetworkUse = true
        try await export(exporter, to: mixedURL, as: .mp4)
        try Task.checkCancellation()
        _ = try fileManager.replaceItemAt(
            sourceURL,
            withItemAt: mixedURL,
            backupItemName: nil,
            options: []
        )
        return sourceURL
    }

    private static func insertTrack(
        _ source: AVAssetTrack,
        into destination: AVMutableCompositionTrack,
        within recordingRange: CMTimeRange
    ) async throws {
        let range = CMTimeRangeGetIntersection(try await source.load(.timeRange), otherRange: recordingRange)
        guard range.isValid, !range.isEmpty else { return }
        // A microphone can start after the first video frame or stop early.
        // Preserve its offset rather than moving the first sound to time zero.
        try destination.insertTimeRange(range, of: source, at: range.start)
    }

    private static func export(
        _ exporter: AVAssetExportSession,
        to destinationURL: URL,
        as fileType: AVFileType
    ) async throws {
        try Task.checkCancellation()
        if #available(macOS 15, *) {
            try await exporter.export(to: destinationURL, as: fileType)
        } else {
            try await exportUsingLegacySession(exporter, to: destinationURL, as: fileType)
        }
        try Task.checkCancellation()
    }

    private final class ExportContinuationState: @unchecked Sendable {
        private let lock = NSLock()
        private var hasResumed = false
        private var savedContinuation: CheckedContinuation<Void, Never>?

        func setContinuation(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if hasResumed {
                return false
            }
            savedContinuation = continuation
            return true
        }

        func resume() {
            lock.lock()
            guard !hasResumed else {
                lock.unlock()
                return
            }
            hasResumed = true
            let continuation = savedContinuation
            savedContinuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    /// macOS 14 has no throwing `export(to:as:)`, so the deprecated
    /// completion-handler export is bridged by hand. The session is a
    /// non-Sendable class used from exactly one task, which the compiler cannot
    /// prove across the escaping handler.
    private static func exportUsingLegacySession(
        _ exporter: AVAssetExportSession,
        to destinationURL: URL,
        as fileType: AVFileType
    ) async throws {
        exporter.outputURL = destinationURL
        exporter.outputFileType = fileType

        nonisolated(unsafe) let session = exporter
        let state = ExportContinuationState()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if !state.setContinuation(continuation) {
                    continuation.resume()
                    return
                }
                session.exportAsynchronously {
                    state.resume()
                }
                if Task.isCancelled {
                    session.cancelExport()
                    state.resume()
                }
            }
        } onCancel: {
            session.cancelExport()
            state.resume()
        }

        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? ScreenRecordingAudioMixdownError.exportFailed
        }
    }
}

enum ScreenRecordingAudioMixdownError: LocalizedError {
    case trackCreationFailed(String)
    case exporterUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case let .trackCreationFailed(kind):
            return "无法创建录屏\(kind)混合轨道"
        case .exporterUnavailable:
            return "系统无法创建录屏音频混合器"
        case .exportFailed:
            return "录屏音频混合导出失败"
        }
    }
}
