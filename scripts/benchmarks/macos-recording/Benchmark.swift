import AVFoundation
import Foundation
// Minimal option model for compiling the production mixdown in isolation.
enum ScreenRecordingFormat { case mp4, gif }
struct ScreenRecordingOptions {
    let format = ScreenRecordingFormat.mp4
    let capturesSystemAudio = true
    let capturesMicrophone = true
}
@main struct Benchmark {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = source.deletingLastPathComponent()
        for iteration in 0..<3 {
            for kind in (iteration % 2 == 0 ? ["before", "after"] : ["after", "before"]) {
                let destination = root.appendingPathComponent("\(kind)-\(iteration).mp4")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                let start = ContinuousClock.now
                if kind == "before" {
                    _ = try await LegacyAudioMixdown.mixIfNeeded(sourceURL: destination, options: ScreenRecordingOptions())
                } else {
                    _ = try await ScreenRecordingAudioMixdown.mixIfNeeded(sourceURL: destination, options: ScreenRecordingOptions())
                }
                let elapsed = start.duration(to: .now)
                print("\(kind) \(iteration): \(elapsed)")
            }
        }
    }
}
