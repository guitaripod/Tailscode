import CodingAgentKit
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(Network)
    import Network
#endif

/// Whether this device has a network to send on at all.
///
/// On Apple platforms a request made with no network does not fail: the session waits for one,
/// silently, for as long as its resource deadline, and a send made in a lift sat "still sending"
/// until a bound gave up on it and called it a failure. Asking the path first turns that into what
/// it is — a message held until there is a network — at once. Elsewhere a request with no network
/// fails on its own, so the path is taken to be usable and the failure is read as it arrives.
public enum DevicePath {
    public static var isUsable: Bool {
        #if canImport(Network)
            return Watch.shared.isUsable
        #else
            return true
        #endif
    }

    /// The sentence a send held because the device has no network carries.
    public static var offlineReason: String {
        TransportWords.sentence(for: URLError(.notConnectedToInternet))
    }

    #if canImport(Network)
        private final class Watch: @unchecked Sendable {
            static let shared = Watch()
            private let monitor = NWPathMonitor()
            private let lock = NSLock()
            private var status: NWPath.Status?

            private init() {
                monitor.pathUpdateHandler = { [weak self] path in
                    guard let self else { return }
                    self.lock.withLock { self.status = path.status }
                }
                monitor.start(queue: DispatchQueue(label: "tailscode.device-path", qos: .utility))
            }

            /// Unknown until the monitor's first answer, which arrives within a moment of the
            /// first send; unknown is read as usable, because holding a send on a guess is worse
            /// than letting the transport say what happened.
            var isUsable: Bool {
                lock.withLock { status.map { $0 == .satisfied } ?? true }
            }
        }
    #endif
}
