import Foundation

/// Where the renderer lives. Video generation does not happen on the phone and never will: it is
/// one machine on the tailnet holding a 96GB card and a ComfyUI that answers on 8188, and every
/// client points at the same one. The address is the whole configuration — there is no account, no
/// key and no project — so it is a value small enough to persist, compare and put in a row.
public struct ForgeEndpoint: Sendable, Codable, Hashable {
    /// ComfyUI's own default, which is what the box on the tailnet actually listens on. A person
    /// typing a bare hostname means this port, so the app supplies it rather than asking.
    public static let defaultPort = 8188

    public let host: String
    public let port: Int

    public init(host: String, port: Int = ForgeEndpoint.defaultPort) {
        self.host = host
        self.port = port
    }

    /// What a person plausibly types or pastes, read through the same parser the agent connection
    /// uses — a bare tailnet address, a MagicDNS name, `host:port`, a full URL, or a whole line
    /// copied out of ComfyUI's startup log. One reader means one set of mistakes to explain.
    public enum Reading: Sendable, Equatable {
        case empty
        case endpoint(ForgeEndpoint)
        case bindAll
        case unsupportedScheme(String)
        case invalid
    }

    public static func read(_ raw: String) -> Reading {
        switch HostAddress.read(raw, defaultPort: defaultPort) {
        case .empty: return .empty
        case .bindAll: return .bindAll
        case .invalid: return .invalid
        case .unsupportedScheme(let scheme): return .unsupportedScheme(scheme)
        case .address(let address):
            guard let host = address.url.host, !host.isEmpty else { return .invalid }
            return .endpoint(ForgeEndpoint(host: host, port: address.url.port ?? defaultPort))
        }
    }

    /// The sentence a client shows when a typed address cannot be used. The reading is a value so
    /// each client can branch on it, but nobody writes their own words for it.
    public static func complaint(_ reading: Reading) -> String? {
        switch reading {
        case .endpoint, .empty: return nil
        case .bindAll:
            return Localized.text("That is the address a server binds to, not one you can reach")
        case .unsupportedScheme(let scheme):
            return Localized.text("%@ is not an address this can open", scheme)
        case .invalid:
            return Localized.text("That does not read as a machine on the tailnet")
        }
    }

    public var displayHost: String { "\(host):\(port)" }

    /// The machine, not the address. A MagicDNS name is a hostname plus a tailnet plus a TLD, and
    /// putting the whole thing on a chip is how a renderer reads as a URL. The first label is what
    /// the tailnet calls the box.
    public var shortName: String {
        if host.hasSuffix(".ts.net") || host.hasSuffix(".tailscale.net"),
            let first = host.split(separator: ".").first
        {
            return String(first)
        }
        return host
    }

    public var baseURL: URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url ?? URL(fileURLWithPath: "/")
    }

    public func url(_ path: String, query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    /// The event socket, which must carry the same client id the submission did or the server
    /// sends this client's frames to somebody else's socket and the job looks like it hung.
    public func socketURL(clientID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        return components.url
    }

    /// Whether anything is listening, asked the only way that can tell "nothing is running there"
    /// from "that machine is asleep" from "that name does not resolve". An HTTP probe cannot, and
    /// this server is socket-activated: the port answers instantly even while the process behind
    /// it is still loading 42GB of weights, so reachability and readiness are different questions
    /// and only this one is cheap.
    public func reach(timeout: Duration = .seconds(3)) async -> PortReachability.Verdict {
        await PortReachability.check(host: host, port: UInt16(clamping: port), timeout: timeout)
    }

    /// What a verdict means here, in words that name the fix. `listening` is deliberately not
    /// "ready": the socket answers before ComfyUI does, and the first render pays for that.
    public static func sentence(for verdict: PortReachability.Verdict, host: String) -> String {
        switch verdict {
        case .listening:
            return Localized.text("%@ is listening", host)
        case .refused:
            return Localized.text("%@ is up but nothing is listening on that port", host)
        case .timedOut:
            return Localized.text("%@ did not answer — it may be asleep or off the tailnet", host)
        case .nameNotResolved:
            return Localized.text("%@ is not a name this machine can resolve", host)
        }
    }
}

/// Why the renderer could not do what was asked, in words a person can act on. Every path that
/// fails names the machine and, where it can, the thing that would fix it — a generation that
/// quietly shows nothing is indistinguishable from one still thinking, and the render takes long
/// enough that the difference matters.
public enum ForgeFailure: Error, CustomStringConvertible, Sendable, Equatable {
    case unconfigured
    case unreachable(String)
    /// The graph was posted and the server would not take it — a missing model, a bad size, a node
    /// this build of ComfyUI does not have. The server's own words are carried through.
    case rejected(String, String)
    case refused(String, String)
    /// The socket dropped mid-render. The job may well still be running on the box, which is why
    /// this is worded as lost contact rather than as a failed render.
    case disconnected(String)
    /// The render finished and left nothing behind, which means the graph's last node saved
    /// nothing — a real failure that the success frames do not describe.
    case noOutput(String)
    case renderFailed(String, String)
    /// The file a kept clip points at is not on the machine any more. A receipt outlives the file
    /// it names — the renderer's output folder is somebody else's to empty — and gone is a
    /// different fact from unreachable: one is a reason to stop waiting, the other is a reason to
    /// wait a little longer.
    case missingFile(String)

    public var host: String {
        switch self {
        case .unconfigured: return ""
        case .unreachable(let host), .rejected(let host, _), .refused(let host, _),
            .disconnected(let host), .noOutput(let host), .renderFailed(let host, _),
            .missingFile(let host):
            return host
        }
    }

    public var description: String {
        switch self {
        case .unconfigured:
            return Localized.text("No renderer is set up yet — point this at the machine with the card")
        case .unreachable(let host):
            return Localized.text("%@ did not answer", host)
        case .rejected(_, let reason):
            return reason
        case .refused(_, let reason):
            return reason
        case .disconnected(let host):
            return Localized.text("Lost contact with %@ while it was rendering", host)
        case .noOutput(let host):
            return Localized.text("%@ finished but saved no video", host)
        case .renderFailed(_, let reason):
            return reason
        case .missingFile(let host):
            return Localized.text("%@ no longer has that clip", host)
        }
    }
}
