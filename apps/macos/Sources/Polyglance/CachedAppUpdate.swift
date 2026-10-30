import CryptoKit
import Foundation
import Network
import Sparkle

struct CachedAppUpdate {
    struct Record: Codable {
        let item: Data
        let package: String
        let feed: Data
    }

    let item: SUAppcastItem
    let package: URL
    let feed: Data

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.polyglance.macos")
            .appendingPathComponent("Updates", isDirectory: true)
    }

    static func signature(for item: SUAppcastItem) -> Data? {
        let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any]
        return (enclosure?["sparkle:edSignature"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    func validate(publicKey: String) throws {
        guard let key = Data(base64Encoded: publicKey), let signature = Self.signature(for: item) else {
            throw NSError(domain: "Polyglance.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新包缺少有效签名。"])
        }
        let data = try Data(contentsOf: package, options: .mappedIfSafe)
        guard try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: data) else {
            throw NSError(domain: "Polyglance.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "更新包签名校验失败。"])
        }
    }

    static func load(publicKey: String) throws -> CachedAppUpdate? {
        let path = directory.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
        guard URL(fileURLWithPath: record.package).lastPathComponent == record.package,
              UUID(uuidString: URL(fileURLWithPath: record.package).deletingPathExtension().lastPathComponent) != nil,
              let item = try NSKeyedUnarchiver.unarchivedObject(ofClass: SUAppcastItem.self, from: record.item) else { return nil }
        let update = CachedAppUpdate(item: item, package: directory.appendingPathComponent(record.package), feed: record.feed)
        try update.validate(publicKey: publicKey)
        return update
    }

    func save() throws {
        let record = Record(item: try NSKeyedArchiver.archivedData(withRootObject: item, requiringSecureCoding: true),
                            package: package.lastPathComponent, feed: feed)
        try JSONEncoder().encode(record).write(to: Self.directory.appendingPathComponent("pending.json"), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pending.json"))
    }
}

final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let progress: @Sendable (Int64, Int64) -> Void

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

final class CachedUpdateServer {
    private final class StartState: @unchecked Sendable { var completed = false }
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.polyglance.update-cache")
    private let token = UUID().uuidString
    private let update: CachedAppUpdate
    private(set) var packageURL: URL?

    init(update: CachedAppUpdate) { self.update = update }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let token = token
        let package = update.package
        let feed = update.feed
        return try await withCheckedThrowingContinuation { continuation in
            let completion = StartState()
            listener.stateUpdateHandler = { state in
                guard !completion.completed else { return }
                switch state {
                case .ready:
                    completion.completed = true
                    guard let port = listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/appcast.xml") else {
                        continuation.resume(throwing: URLError(.badURL))
                        return
                    }
                    self.packageURL = url.deletingLastPathComponent().appendingPathComponent("update." + package.pathExtension)
                    continuation.resume(returning: url)
                case .failed(let error):
                    completion.completed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, listener.port != nil else { connection.cancel(); return }
                let filePath = "/\(token)/update.\(package.pathExtension)"
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data(), feedPath: "/\(token)/appcast.xml", filePath: filePath, feed: feed, package: package)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data, feedPath: String, filePath: String, feed: Data, package: URL) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = buffer
            request.append(data ?? Data())
            guard request.count <= 8192 else { connection.cancel(); return }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, buffer: request, feedPath: feedPath, filePath: filePath, feed: feed, package: package) }
                return
            }
            let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
            guard line.count == 3, line[0] == "GET" else { connection.cancel(); return }
            let body: Data
            if line[1] == Substring(feedPath) { body = feed }
            else if line[1] == Substring(filePath), let data = try? Data(contentsOf: package, options: .mappedIfSafe) { body = data }
            else { connection.cancel(); return }
            let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
            connection.send(content: header, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                connection.send(content: body, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            })
        }
    }

    func stop() { listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil }
    deinit { listener?.cancel() }
}
