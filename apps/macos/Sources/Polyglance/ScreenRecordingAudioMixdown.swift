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
        let composition = AVMutableComposition()

        for sourceVideoTrack in try await sourceAsset.loadTracks(withMediaType: .video) {
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ScreenRecordingAudioMixdownError.trackCreationFailed("视频")
            }
            try destinationTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
            destinationTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        }

        var inputParameters: [AVMutableAudioMixInputParameters] = []
        for sourceAudioTrack in audioTracks {
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw ScreenRecordingAudioMixdownError.trackCreationFailed("音频")
            }
            try destinationTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
            let parameters = AVMutableAudioMixInputParameters(track: destinationTrack)
            parameters.setVolume(1, at: .zero)
            inputParameters.append(parameters)
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ScreenRecordingAudioMixdownError.exporterUnavailable
        }
        exporter.audioMix = audioMix
        exporter.shouldOptimizeForNetworkUse = true

        let mixedURL = sourceURL.deletingLastPathComponent().appendingPathComponent(
            ".\(sourceURL.deletingPathExtension().lastPathComponent)-mixed-\(UUID().uuidString).mp4"
        )
        defer { try? fileManager.removeItem(at: mixedURL) }
        if #available(macOS 15, *) {
            try await exporter.export(to: mixedURL, as: .mp4)
        } else {
            try await exportUsingLegacySession(exporter, to: mixedURL)
        }
        _ = try fileManager.replaceItemAt(
            sourceURL,
            withItemAt: mixedURL,
            backupItemName: nil,
            options: []
        )
        return sourceURL
    }

    /// macOS 14 has no throwing `export(to:as:)`, so the deprecated
    /// completion-handler export is bridged by hand. The session is a
    /// non-Sendable class used from exactly one task, which the compiler cannot
    /// prove across the escaping handler.
    private static func exportUsingLegacySession(
        _ exporter: AVAssetExportSession,
        to destinationURL: URL
    ) async throws {
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4

        nonisolated(unsafe) let session = exporter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
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
