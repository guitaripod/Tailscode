import Foundation

/// What a pane is for, without the detail of what it is showing. Layout, sizing and the governor
/// decide on kind alone; the address, session or endpoint stays in `PaneContent`.
public enum PaneKind: String, Codable, Sendable, CaseIterable {
    case empty
    case chat
    case web
    case video
    case draw
}

/// What one pane holds, as one value. A snapshot used to carry four parallel dictionaries keyed by
/// pane id, so every new kind of slot meant a new dictionary and a new branch in each host's
/// restore; a sum type makes the question "what is in this pane" one switch that cannot be
/// forgotten.
public enum PaneContent: Sendable, Equatable {
    case empty
    case chat(SplitPaneSession)
    case web(String)
    case video(String)
    case draw(String)

    public var kind: PaneKind {
        switch self {
        case .empty: return .empty
        case .chat: return .chat
        case .web: return .web
        case .video: return .video
        case .draw: return .draw
        }
    }
}

extension PaneContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case profileID
        case sessionID
        case address
    }

    /// An unknown kind, or a known one missing what it needs, decodes as an empty pane. A snapshot
    /// written by a newer build must never invalidate the layout an older one can still draw.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let address = try container.decodeIfPresent(String.self, forKey: .address)
        switch PaneKind(rawValue: raw) {
        case .chat:
            let profile = try container.decodeIfPresent(String.self, forKey: .profileID)
            let session = try container.decodeIfPresent(String.self, forKey: .sessionID)
            if let profile, let session {
                self = .chat(SplitPaneSession(profileID: profile, sessionID: session))
            } else {
                self = .empty
            }
        case .web: self = address.map(PaneContent.web) ?? .empty
        case .video: self = address.map(PaneContent.video) ?? .empty
        case .draw: self = address.map(PaneContent.draw) ?? .empty
        case .empty, .none: self = .empty
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .empty: break
        case .chat(let session):
            try container.encode(session.profileID, forKey: .profileID)
            try container.encode(session.sessionID, forKey: .sessionID)
        case .web(let address), .video(let address), .draw(let address):
            try container.encode(address, forKey: .address)
        }
    }
}

/// How much of a pane is alive. Parked panes own no stream and no clock; glance panes show a
/// status tile fed at a low rate; full panes are the whole conversation. Density is ordered so a
/// budget can be spent from the top.
public enum PaneDensity: Int, Codable, Sendable, Comparable {
    case parked = 0
    case glance = 1
    case full = 2

    public static func < (lhs: PaneDensity, rhs: PaneDensity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
