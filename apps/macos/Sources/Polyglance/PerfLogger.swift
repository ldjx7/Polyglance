import Foundation

enum PerfLogger {
    private static let logPath = "/tmp/polyglance_perf.log"

    static func log(_ message: String) {
        NSLog("%@", message)
        print(message)
        let descriptor = open(logPath, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try? handle.write(contentsOf: Data("\(Date()) \(message)\n".utf8))
    }
}
