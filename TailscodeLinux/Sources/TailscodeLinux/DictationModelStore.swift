import CAdw
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One file the Linux engine needs, as k2-fsa publishes it: where it is, the SHA-256 GitHub
/// records for it, and its size.
struct DictationModelFile: Sendable, Equatable {
    let name: String
    let url: URL
    let sha256: String
    let bytes: Int64
}

/// The engine and the model dictation listens with on this machine: sherpa-onnx's shared library
/// for the CPU it runs on, and NVIDIA's Nemotron Speech Streaming 0.6B, int8, in 160 ms chunks.
/// Both are pinned by digest, so a changed or truncated download is refused rather than loaded.
enum DictationModelPack {
    static let id = "nemotron-0.6b-160ms-int8-sherpa-2.0.1"
    static let modelName = "Nemotron · English"
    static let license = "NVIDIA Open Model"

    static var engine: DictationModelFile? {
        #if arch(x86_64)
            return DictationModelFile(
                name: "sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib.tar.bz2",
                url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-linux-x64-shared-no-tts-lib.tar.bz2")!,
                sha256: "ce437357915491e6f2754b52bec7dcf62ff6fc6aaed9cdcd66f17807bbaef374", bytes: 9_374_461)
        #elseif arch(arm64)
            return DictationModelFile(
                name: "sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu-lib.tar.bz2",
                url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-linux-aarch64-shared-cpu-lib.tar.bz2")!,
                sha256: "15bd737eae467da32ec97e3740a329a535fd21e33caca4f327b0081451d11533", bytes: 12_500_491)
        #else
            return nil
        #endif
    }

    static let model = DictationModelFile(
        name: "sherpa-onnx-nemotron-speech-streaming-en-0.6b-160ms-int8-2026-04-25.tar.bz2",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemotron-speech-streaming-en-0.6b-160ms-int8-2026-04-25.tar.bz2")!,
        sha256: "0ae73a41cd51599dc7cac9ac083d9d35de53d762ca45923505fde47a3751814b", bytes: 463_945_198)

    static var files: [DictationModelFile] { [engine, model].compactMap { $0 } }

    static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Whether this CPU has an engine build at all.
    static var isSupported: Bool { engine != nil }
}

/// Where the download stands, for the popover's bar.
struct DictationDownload: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case downloading
        case unpacking
        case ready
    }

    var done: Int64
    var total: Int64
    var stage: Stage
    var bytesPerSecond: Double

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    var secondsLeft: Double {
        guard bytesPerSecond > 1 else { return .infinity }
        return Double(max(0, total - done)) / bytesPerSecond
    }
}

enum DictationModelError: Error, Sendable, Equatable {
    case unsupportedCPU
    case http(Int)
    case digest(String)
    case unpack(String)
    case cancelled
    case io(String)
}

/// The engine and model on disk: fetched once into `$XDG_DATA_HOME/tailscode/dictation/<pack>`,
/// verified, unpacked, and marked installed only when every file is in place. One install runs at
/// a time and anything watching it reads the same progress.
final class DictationModelStore: NSObject, @unchecked Sendable {
    static let shared = DictationModelStore()
    static let markerName = "installed.json"

    enum State: Sendable, Equatable {
        case absent
        case installing(DictationDownload)
        case installed
        case failed(String)
    }

    private let lock = NSLock()
    private var current: State = .absent
    private var watchers: [UUID: @Sendable (State) -> Void] = [:]
    private var installTask: Task<Void, Never>?
    private var session: URLSession?
    private var receiving: Receiving?

    override init() {
        super.init()
        current = isComplete ? .installed : .absent
    }

    var state: State { lock.withLock { current } }

    static var directory: URL {
        let environment = ProcessInfo.processInfo.environment
        let base =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return base.appendingPathComponent("tailscode/dictation/\(DictationModelPack.id)", isDirectory: true)
    }

    /// The four model files and the engine library, once unpacked.
    struct Paths: Sendable {
        let library: String
        let encoder: String
        let decoder: String
        let joiner: String
        let tokens: String
    }

    var paths: Paths? {
        let root = Self.directory
        let model = root.appendingPathComponent(Self.folder(of: DictationModelPack.model), isDirectory: true)
        guard let library = Self.find("libsherpa-onnx-c-api.so", under: root.appendingPathComponent("engine")) else {
            return nil
        }
        let paths = Paths(
            library: library, encoder: model.appendingPathComponent("encoder.int8.onnx").path,
            decoder: model.appendingPathComponent("decoder.int8.onnx").path,
            joiner: model.appendingPathComponent("joiner.int8.onnx").path,
            tokens: model.appendingPathComponent("tokens.txt").path)
        let all = [paths.library, paths.encoder, paths.decoder, paths.joiner, paths.tokens]
        return all.allSatisfy { FileManager.default.isReadableFile(atPath: $0) } ? paths : nil
    }

    var isComplete: Bool {
        FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent(Self.markerName).path) && paths != nil
    }

    var bytesOnDisk: Int64 {
        guard let walker = FileManager.default.enumerator(at: Self.directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    @discardableResult
    func watch(_ handler: @escaping @Sendable (State) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { watchers[id] = handler }
        handler(state)
        return id
    }

    func unwatch(_ id: UUID) {
        _ = lock.withLock { watchers.removeValue(forKey: id) }
    }

    /// Starts the download if nothing is running; the progress arrives through `watch`.
    func install() {
        let alreadyRunning = lock.withLock { () -> Bool in
            if installTask != nil { return true }
            if case .installed = current { return true }
            return false
        }
        guard !alreadyRunning else { return }
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runInstall()
        }
        lock.withLock { installTask = task }
    }

    func cancel() {
        let (task, session) = lock.withLock { (installTask, self.session) }
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func remove() throws {
        cancel()
        try? FileManager.default.removeItem(at: Self.directory)
        publish(.absent)
    }

    private func publish(_ state: State) {
        let handlers = lock.withLock { () -> [@Sendable (State) -> Void] in
            current = state
            return Array(watchers.values)
        }
        handlers.forEach { $0(state) }
    }

    private func runInstall() async {
        defer {
            lock.withLock {
                installTask = nil
                session = nil
            }
        }
        let root = Self.directory
        let total = DictationModelPack.totalBytes
        var done: Int64 = 0
        do {
            guard DictationModelPack.isSupported else { throw DictationModelError.unsupportedCPU }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.markerName))
            let started = ProcessInfo.processInfo.systemUptime
            publish(.installing(DictationDownload(done: 0, total: total, stage: .downloading, bytesPerSecond: 0)))
            for file in DictationModelPack.files {
                let archive = root.appendingPathComponent(file.name)
                if !(FileManager.default.fileExists(atPath: archive.path) && Self.sha256(of: archive) == file.sha256) {
                    let base = done
                    try await download(file, to: archive) { [weak self] received in
                        let sofar = base + received
                        let elapsed = max(0.1, ProcessInfo.processInfo.systemUptime - started)
                        self?.publish(
                            .installing(
                                DictationDownload(
                                    done: sofar, total: total, stage: .downloading, bytesPerSecond: Double(sofar) / elapsed)))
                    }
                    try Task.checkCancellation()
                    let digest = Self.sha256(of: archive)
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: archive)
                        throw DictationModelError.digest(file.name)
                    }
                }
                done += file.bytes
            }
            publish(.installing(DictationDownload(done: total, total: total, stage: .unpacking, bytesPerSecond: 0)))
            if let engine = DictationModelPack.engine {
                let into = root.appendingPathComponent("engine", isDirectory: true)
                try? FileManager.default.removeItem(at: into)
                try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
                try Self.unpack(root.appendingPathComponent(engine.name), into: into)
            }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(Self.folder(of: DictationModelPack.model)))
            try Self.unpack(root.appendingPathComponent(DictationModelPack.model.name), into: root)
            for file in DictationModelPack.files {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file.name))
            }
            try? FileManager.default.removeItem(
                at: root.appendingPathComponent(Self.folder(of: DictationModelPack.model)).appendingPathComponent("test_wavs"))
            guard paths != nil else { throw DictationModelError.unpack("files missing after unpacking") }
            let marker = ["pack": DictationModelPack.id, "installed": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: marker).write(to: root.appendingPathComponent(Self.markerName))
            AppLog.write(.session, "dictation: model installed at \(root.path)")
            publish(.installed)
        } catch {
            let cancelled = Task.isCancelled || (error as? DictationModelError) == .cancelled
            for file in DictationModelPack.files {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file.name + ".part"))
            }
            AppLog.write(.session, "dictation: model install \(cancelled ? "cancelled" : "failed: \(error)")")
            publish(cancelled ? .absent : .failed(String(describing: error)))
        }
    }

    /// Streams one file straight to disk beside where it ends up, so nothing the size of the model
    /// ever passes through `/tmp`.
    private func download(_ file: DictationModelFile, to destination: URL, progress: @escaping @Sendable (Int64) -> Void)
        async throws
    {
        let part = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: part)
        guard FileManager.default.createFile(atPath: part.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: part)
        else { throw DictationModelError.io("cannot write \(part.path)") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let receiving = Receiving(handle: handle, progress: progress, continuation: continuation)
            let session = URLSession(configuration: .default, delegate: receiving, delegateQueue: nil)
            lock.withLock {
                self.session = session
                self.receiving = receiving
            }
            session.dataTask(with: file.url).resume()
        }
        try? handle.close()
        lock.withLock { receiving = nil }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    private final class Receiving: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let progress: @Sendable (Int64) -> Void
        private var continuation: CheckedContinuation<Void, Error>?
        private var received: Int64 = 0
        private var reported: TimeInterval = 0
        private var status = 200

        init(handle: FileHandle, progress: @escaping @Sendable (Int64) -> Void, continuation: CheckedContinuation<Void, Error>) {
            self.handle = handle
            self.progress = progress
            self.continuation = continuation
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 200
            completionHandler(status == 200 ? .allow : .cancel)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            handle.write(data)
            received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - reported > 0.2 {
                reported = now
                progress(received)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            progress(received)
            let continuation = self.continuation
            self.continuation = nil
            session.finishTasksAndInvalidate()
            if status != 200 {
                continuation?.resume(throwing: DictationModelError.http(status))
            } else if let error {
                let cancelled = (error as NSError).code == NSURLErrorCancelled
                continuation?.resume(throwing: cancelled ? DictationModelError.cancelled : DictationModelError.io(error.localizedDescription))
            } else {
                continuation?.resume()
            }
        }
    }

    private static func unpack(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tar", "-xjf", archive.path, "-C", directory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DictationModelError.unpack("tar did not start: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let words = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DictationModelError.unpack(words.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// The SHA-256 of a file, read in pieces through GLib, which every desktop this runs on has.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url), let checksum = g_checksum_new(G_CHECKSUM_SHA256) else {
            return nil
        }
        defer {
            try? handle.close()
            g_checksum_free(checksum)
        }
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            chunk.withUnsafeBytes { raw in
                g_checksum_update(checksum, raw.bindMemory(to: guchar.self).baseAddress, gssize(chunk.count))
            }
        }
        return g_checksum_get_string(checksum).map { String(cString: $0) }
    }

    private static func folder(of file: DictationModelFile) -> String {
        file.name.replacingOccurrences(of: ".tar.bz2", with: "")
    }

    private static func find(_ name: String, under directory: URL) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else { return nil }
        for case let relative as String in walker where (relative as NSString).lastPathComponent == name {
            return directory.appendingPathComponent(relative).path
        }
        return nil
    }
}
