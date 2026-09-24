import AVFoundation
import XCTest
@testable import Polyglance

final class ScreenRecordingPassthroughTests: XCTestCase {
    func testMixPreservesCompressedVideoTimingAndDelayedMicrophone() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeRecording(in: directory, audioTrackCount: 2)
        let originalAsset = AVURLAsset(url: url)
        let originalVideo = try await videoSamples(originalAsset)
        let originalDuration = try await originalAsset.load(.duration)
        let originalTracks = try await originalAsset.loadTracks(withMediaType: .video)
        let originalTransform = try await XCTUnwrap(originalTracks.first).load(.preferredTransform)

        let result = try await ScreenRecordingAudioMixdown.mixIfNeeded(sourceURL: url, options: dualAudioOptions)

        XCTAssertEqual(result, url)
        let resultAsset = AVURLAsset(url: result)
        let resultVideo = try await videoSamples(resultAsset)
        XCTAssertFalse(originalVideo.isEmpty)
        XCTAssertEqual(resultVideo, originalVideo, "Compressed bytes, PTS, DTS and durations must be unchanged")
        let audioTracks = try await resultAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await resultAsset.load(.duration)
        XCTAssertEqual(duration.seconds, originalDuration.seconds, accuracy: 0.001)
        let videoTracks = try await resultAsset.loadTracks(withMediaType: .video)
        let transform = try await XCTUnwrap(videoTracks.first).load(.preferredTransform)
        XCTAssertEqual(transform, originalTransform)

        let audio = try await decodedAudio(resultAsset)
        // The system track runs from 0 to 1.8 s; the mic from 0.5 to 1.1 s.
        // Detect both tones, and ensure the microphone was not shifted to zero.
        XCTAssertGreaterThan(toneAmplitude(audio, frequency: 440, start: 0.1), 0.05)
        XCTAssertLessThan(toneAmplitude(audio, frequency: 880, start: 0.1), 0.01)
        XCTAssertGreaterThan(toneAmplitude(audio, frequency: 440, start: 0.7), 0.05)
        XCTAssertGreaterThan(toneAmplitude(audio, frequency: 880, start: 0.7), 0.05)
        XCTAssertLessThan(toneAmplitude(audio, frequency: 880, start: 1.4), 0.01)
        XCTAssertGreaterThan(toneAmplitude(audio, frequency: 440, start: 1.4), 0.05)
        XCTAssertLessThan(toneAmplitude(audio, frequency: 440, start: 1.9), 0.01)
        try assertNoTemporaryMixFiles(directory)
    }

    func testSingleActualAudioTrackIsNotRewritten() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeRecording(in: directory, audioTrackCount: 1)
        let original = try Data(contentsOf: url)
        _ = try await ScreenRecordingAudioMixdown.mixIfNeeded(sourceURL: url, options: dualAudioOptions)
        XCTAssertEqual(try Data(contentsOf: url), original)
        try assertNoTemporaryMixFiles(directory)
    }

    func testCancelledMixKeepsOriginalRecordingAndCleansTemporaryFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await makeRecording(in: directory, audioTrackCount: 2)
        let original = try Data(contentsOf: url)
        let options = dualAudioOptions
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenRecordingAudioMixdown.mixIfNeeded(sourceURL: url, options: options)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled mixing must not replace the original recording")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        try assertNoTemporaryMixFiles(directory)
    }

    private var dualAudioOptions: ScreenRecordingOptions {
        ScreenRecordingOptions(format: .mp4, quality: .standard, capturesSystemAudio: true, capturesMicrophone: true)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertNoTemporaryMixFiles(_ directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.contains { $0.hasPrefix(".") && ($0.contains("-audio-") || $0.contains("-mixed-")) })
    }

    private func makeRecording(in directory: URL, audioTrackCount: Int) async throws -> URL {
        let videoURL = directory.appendingPathComponent("video.mp4")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(15)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else { throw FixtureError.writeFailed }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var optionalBuffer: CVPixelBuffer?
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            memset(base, Int32(frame * 7), CVPixelBufferGetBytesPerRow(buffer) * 90)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            // A real timestamp gap exercises variable frame timing preservation.
            let time = CMTime(value: Int64(frame * 2 + (frame >= 15 ? 1 : 0)), timescale: 30)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }
        writer.endSession(atSourceTime: CMTime(value: 62, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let destinationVideo = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try destinationVideo.insertTimeRange(try await video.load(.timeRange), of: video, at: .zero)
        destinationVideo.preferredTransform = try await video.load(.preferredTransform)
        for index in 0..<audioTrackCount {
            let audioURL = directory.appendingPathComponent("tone\(index).m4a")
            try makeTone(at: audioURL, frequency: index == 0 ? 440 : 880, duration: index == 0 ? 1.8 : 0.6)
            let asset = AVURLAsset(url: audioURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let destination = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try destination.insertTimeRange(try await track.load(.timeRange), of: track,
                                            at: CMTime(seconds: index == 0 ? 0 : 0.5, preferredTimescale: 48_000))
        }
        let outputURL = directory.appendingPathComponent("recording.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        if #available(macOS 15, *) {
            try await exporter.export(to: outputURL, as: .mp4)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .mp4
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                exporter.exportAsynchronously {
                    continuation.resume()
                }
            }
            if let error = exporter.error { throw error }
            XCTAssertEqual(exporter.status, .completed)
        }
        let tracks = try await AVURLAsset(url: outputURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, audioTrackCount)
        return outputURL
    }

    private func makeTone(at url: URL, frequency: Double, duration: Double) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ])
        let count = AVAudioFrameCount(duration * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
        buffer.frameLength = count
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(count) {
            samples[index] = Float(0.15 * sin(2 * .pi * frequency * Double(index) / 48_000))
        }
        try file.write(from: buffer)
    }

    private struct VideoSample: Equatable {
        let data: Data
        let presentation: CMTime
        let decode: CMTime
        let duration: CMTime
    }

    private func videoSamples(_ asset: AVAsset) async throws -> [VideoSample] {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [VideoSample] = []
        while let sample = output.copyNextSampleBuffer() {
            var data = Data()
            if let buffer = CMSampleBufferGetDataBuffer(sample) {
                data = Data(count: CMBlockBufferGetDataLength(buffer))
                let status = data.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
                }
                XCTAssertEqual(status, kCMBlockBufferNoErr)
            }
            samples.append(VideoSample(data: data, presentation: CMSampleBufferGetPresentationTimeStamp(sample),
                                       decode: CMSampleBufferGetDecodeTimeStamp(sample), duration: CMSampleBufferGetDuration(sample)))
        }
        XCTAssertEqual(reader.status, .completed)
        return samples
    }

    private func decodedAudio(_ asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        // Missing audio samples after a track ends represent silence while the
        // video continues. Reconstruct the full recording timeline for checks.
        let duration = try await asset.load(.duration)
        var result = [Float](repeating: 0, count: Int(ceil(duration.seconds * 48_000)))
        while let sample = output.copyNextSampleBuffer() {
            let buffer = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(buffer) / 4)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let offset = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * 48_000).rounded())
            for (index, value) in values.enumerated() {
                let position = offset + index
                if position >= 0, position < result.count { result[position] = value }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return result
    }

    private func toneAmplitude(_ audio: [Float], frequency: Double, start: Double) -> Double {
        let offset = Int(start * 48_000)
        let count = 4_800
        guard offset + count <= audio.count else {
            XCTFail("Mixed audio ended before the expected recording duration")
            return .infinity
        }
        var real = 0.0
        var imaginary = 0.0
        for index in 0..<count {
            let angle = 2 * .pi * frequency * Double(index) / 48_000
            real += Double(audio[offset + index]) * cos(angle)
            imaginary += Double(audio[offset + index]) * sin(angle)
        }
        return 2 * hypot(real, imaginary) / Double(count)
    }

    private enum FixtureError: Error { case writeFailed }
}
