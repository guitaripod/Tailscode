import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum VoiceTransportError: Error, Sendable, Equatable {
    case notConnected
    case refused(String)
}

/// The call's socket over `URLSessionWebSocketTask`, which Linux's Foundation carries too.
///
/// `receive()` installs no cancellation handler, so the stream's termination closes the socket,
/// which is the only thing that makes a parked `receive()` return. The handshake is proven by a
/// ping before `connect` returns, so a refused or unreachable gateway throws there rather than
/// surfacing as a stream that ends.
public final class URLSessionVoiceTransport: VoiceTransport, @unchecked Sendable {
    public static let handshakeTimeout: TimeInterval = 8

    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, bearer: String?) async throws {
        var request = URLRequest(url: url, timeoutInterval: Self.handshakeTimeout)
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let task = session.webSocketTask(with: request)
        replace(with: task)?.cancel(with: .goingAway, reason: nil)
        task.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            _ = replace(with: nil)
            throw VoiceTransportError.refused(error.localizedDescription)
        }
    }

    public func sendBinary(_ data: Data) async throws {
        try await current().send(.data(data))
    }

    public func sendText(_ text: String) async throws {
        try await current().send(.string(text))
    }

    public func receive() -> AsyncThrowingStream<VoiceFrame, Error> {
        guard let task = held() else {
            return AsyncThrowingStream { $0.finish(throwing: VoiceTransportError.notConnected) }
        }
        return AsyncThrowingStream { continuation in
            let reader = Task {
                while !Task.isCancelled {
                    do {
                        switch try await task.receive() {
                        case .string(let text): continuation.yield(.text(text))
                        case .data(let data): continuation.yield(.binary(data))
                        @unknown default: continue
                        }
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    public func close() async {
        replace(with: nil)?.cancel(with: .goingAway, reason: nil)
    }

    private func held() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return socket
    }

    private func current() throws -> URLSessionWebSocketTask {
        guard let task = held() else { throw VoiceTransportError.notConnected }
        return task
    }

    @discardableResult
    private func replace(with task: URLSessionWebSocketTask?) -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        let old = socket
        socket = task
        return old
    }
}
