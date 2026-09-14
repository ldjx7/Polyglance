import Foundation

enum PerfLogger {
    private static let logURL = URL(fileURLWithPath: "/tmp/polyglance_perf.log")
    private static let lock = NSLock()

    static func log(_ message: String) {
        NSLog("%@", message)
        print(message)
        lock.lock()
        defer { lock.unlock() }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
