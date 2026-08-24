import AVFoundation
import XCTest
@testable import Polyglance

final class AudioMixdownIntegrationTests: XCTestCase {
    func testTwoAudioTracksAreExportedAsOneMixedTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Polyglance.AudioMixdownTests.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstTone = directory.appendingPathComponent("system.caf")
        let secondTone = directory.appendingPathComponent("microphone.caf")
        let sourceURL = directory.appendingPathComponent("source.mp4")
        try makeTone(at: firstTone, frequency: 440)
        try makeTone(at: secondTone, frequency: 660)
        try await makeTwoTrackMP4(audioURLs: [firstTone, secondTone], outputURL: sourceURL)

        let beforeTracks = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(beforeTracks.count, 2)

        let options = ScreenRecordingOptions(
            format: .mp4,
            quality: .standard,
            frameRate: 30,
            capturesSystemAudio: true,
            capturesMicrophone: true,
            showsCursor: true
        )
        _ = try await ScreenRecordingAudioMixdown.mixIfNeeded(
            sourceURL: sourceURL,
            options: options
        )

        let afterTracks = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .audio)
        XCTAssertEqual(afterTracks.count, 1)
    }

    private func makeTone(at url: URL, frequency: Double) throws {
        let frameCount: AVAudioFrameCount = 48_000
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = Float(sin(2 * .pi * frequency * Double(index) / 48_000) * 0.15)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func makeTwoTrackMP4(audioURLs: [URL], outputURL: URL) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        var readers: [AVAssetReader] = []
        var outputs: [AVAssetReaderTrackOutput] = []
        var inputs: [AVAssetWriterInput] = []

        for url in audioURLs {
            let asset = AVURLAsset(url: url)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            let sourceTrack = try XCTUnwrap(sourceTracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: sourceTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 96_000,
                ]
            )
            input.expectsMediaDataInRealTime = false
            XCTAssertTrue(writer.canAdd(input))
            writer.add(input)
            readers.append(reader)
            outputs.append(output)
            inputs.append(input)
        }

        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for reader in readers {
            XCTAssertTrue(reader.startReading())
        }

        var finished = Array(repeating: false, count: inputs.count)
        while finished.contains(false) {
            var madeProgress = false
            for index in inputs.indices where !finished[index] && inputs[index].isReadyForMoreMediaData {
                if let sampleBuffer = outputs[index].copyNextSampleBuffer() {
                    XCTAssertTrue(inputs[index].append(sampleBuffer))
                } else {
                    inputs[index].markAsFinished()
                    finished[index] = true
                }
                madeProgress = true
            }
            if !madeProgress {
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? ScreenRecordingAudioMixdownTestError.writerFailed
        }
    }
}

private enum ScreenRecordingAudioMixdownTestError: Error {
    case writerFailed
}
