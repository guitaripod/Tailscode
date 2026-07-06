import Foundation

/// Append-only, size-rotated file logger at `Library/Logs/tailscode.log` (+ `.previous.log`).
/// Writes are serialized on a utility queue. Pull with pymobiledevice3 / devicectl.
final class LogFileWriter: @unchecked Sendable {
    static let shared = LogFileWriter()

    private let queue = DispatchQueue(label: "com.guitaripod.tailscode.logwriter", qos: .utility)
    private let maxBytes = 512 * 1024
    private let fileURL: URL
    private let previousURL: URL
    private let formatter = ISO8601DateFormatter()

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        fileURL = logs.appendingPathComponent("tailscode.log")
        previousURL = logs.appendingPathComponent("tailscode.previous.log")
    }

    func write(_ line: String) {
        let timestamp = formatter.string(from: Date())
        queue.async { [self] in
            rotateIfNeeded()
            guard let data = "\(timestamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? Int, size > maxBytes
        else { return }
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousURL)
    }
}
