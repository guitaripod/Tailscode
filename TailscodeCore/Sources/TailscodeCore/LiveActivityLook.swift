import Foundation

/// How much of the Lock Screen a turn's card takes. The platform gives a card between 84 and 160
/// points of height and never lets an app ask for more, so the three sizes are three layouts inside
/// that envelope: the line alone, the line with the turn's pulse, and the whole tile as the wall
/// draws it with room — its plan, its latest steps and how it ended.
public enum LiveActivitySize: String, Sendable, CaseIterable, Codable {
    case compact
    case standard
    case large

    public var title: String {
        switch self {
        case .compact: return Localized.text("Compact")
        case .standard: return Localized.text("Standard")
        case .large: return Localized.text("Large")
        }
    }

    public var explanation: String {
        switch self {
        case .compact:
            return Localized.text("One slim row: what the agent is doing and the turn’s clock.")
        case .standard:
            return Localized.text(
                "The line in large type, who is answering, and the last minute of the agent’s pulse.")
        case .large:
            return Localized.text(
                "The whole tile, as the Agents wall draws it: the plan, the latest steps, and what the agent said when it finished.")
        }
    }
}

/// What a card does when its turn ends while the phone is in someone's hand. The Dynamic Island
/// opens on its own only for an update that alerts, so an ending that should be seen alerts; the
/// sound is a separate choice because the notification for the same ending usually carries one.
public enum LiveActivityEnding: String, Sendable, CaseIterable, Codable {
    /// The island opens on how the turn ended and the screen lights, without a sound.
    case expand
    case expandWithSound
    /// The card settles in place and says nothing.
    case stay

    public var title: String {
        switch self {
        case .expand: return Localized.text("Open the island")
        case .expandWithSound: return Localized.text("Open the island with a sound")
        case .stay: return Localized.text("Stay closed")
        }
    }

    public var explanation: String {
        switch self {
        case .expand:
            return Localized.text(
                "The Dynamic Island opens on how the turn ended and the Lock Screen lights up, silently. A notification still brings its own sound.")
        case .expandWithSound:
            return Localized.text(
                "The Dynamic Island opens on how the turn ended with the notification sound.")
        case .stay:
            return Localized.text("The card settles in place without opening.")
        }
    }

    /// Whether an ending alerts at all.
    public var alerts: Bool { self != .stay }

    /// What a server that pushes the card is asked to do at the ending, as the registration's
    /// `endAlert`: a wire word, added and never renamed.
    public var wire: String? {
        switch self {
        case .expand: return "silent"
        case .expandWithSound: return "sound"
        case .stay: return nil
        }
    }

    /// The bundled sound an alert that must not be heard plays: a tenth of a second of silence,
    /// because the platform's alert has no silent sound of its own.
    public static let silentSound = "LiveActivityQuiet.caf"
}

/// The person's choices for the card, kept in the shared container so the widget that draws the
/// card reads the same answer the app wrote. Device-local, never synced.
public enum LiveActivitySettings {
    public static let sizeKey = "tailscode.liveActivity.size"
    public static let endingKey = "tailscode.liveActivity.ending"
    public static let didChange = Notification.Name("tailscode.liveActivity.didChange")

    /// The shared suite both processes read; nil reads the process's own defaults, which is what a
    /// test and a client without a widget want.
    public nonisolated(unsafe) static var suiteName: String?

    private static var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    public static var size: LiveActivitySize {
        defaults.string(forKey: sizeKey).flatMap(LiveActivitySize.init(rawValue:)) ?? .standard
    }

    public static var ending: LiveActivityEnding {
        defaults.string(forKey: endingKey).flatMap(LiveActivityEnding.init(rawValue:)) ?? .expand
    }

    public static func set(_ size: LiveActivitySize) {
        defaults.set(size.rawValue, forKey: sizeKey)
        StoreNotice.post(didChange)
    }

    public static func set(_ ending: LiveActivityEnding) {
        defaults.set(ending.rawValue, forKey: endingKey)
        StoreNotice.post(didChange)
    }

    public static let followsElsewhereKey = "tailscode.liveActivity.followsElsewhere"

    /// Whether a card also follows turns this device did not send: one sent from a desktop or
    /// another phone, drained from a queue, run on a schedule, or begun by the machine itself.
    /// On until somebody turns it off.
    public static var followsElsewhere: Bool {
        defaults.object(forKey: followsElsewhereKey) as? Bool ?? true
    }

    public static func setFollowsElsewhere(_ value: Bool) {
        defaults.set(value, forKey: followsElsewhereKey)
        StoreNotice.post(didChange)
    }

    public static var followsElsewhereTitle: String { Localized.text("Follow turns started elsewhere") }

    public static var followsElsewhereExplanation: String {
        Localized.text(
            "A card also appears for chats working while Tailscode is open, up to four at once, and — from claude-bridge — for turns sent from a desktop, a queue or a schedule while the phone is locked. Muted chats never get one.")
    }

    public static var sizeTitle: String { Localized.text("Card size") }
    public static var endingTitle: String { Localized.text("When a turn ends") }
    public static var screenTitle: String { Localized.text("Live Activity") }

    public static var explanation: String {
        Localized.text(
            "The card follows a turn on the Lock Screen and in the Dynamic Island in the Agents wall’s colours and words. It stays after the turn ends until you open the chat.")
    }
}

/// What a card looks like, read from what it says: the wall's state for the colour and the mark,
/// and the one word beside the mark. Toolkit-free, so the widget, the in-app preview and the tests
/// draw the same card from the same content.
public struct LiveActivityLook: Sendable, Equatable {
    /// The mark the orb wears, the way a wall tile's glyph says its state.
    public enum Mark: Sendable, Equatable {
        /// A lit core inside the context ring: work, or thinking in the thinking ink.
        case orb
        /// The amber hand of a turn stopped for the person.
        case ask
        /// A ring with one dot on it: the turn ended and the machine still carries work for it.
        case background
        /// The context ring with a flat line through it: nothing seen for a while.
        case quiet
        case check
        case cross
        case stop
        case unknown
    }

    public let state: WallState
    public let mark: Mark
    /// The symbol for a presentation too small for the orb: the compact Dynamic Island.
    public let symbol: String
    public let tone: ActivityTone

    /// Whether the card is still moving, which is the only time anything on it may change light.
    public var isLive: Bool { state.isRunning }

    /// The face of a card. `quietSince` is when it was last seen to move, given only when it has
    /// been still long enough to say so.
    public static func read(
        detail: LiveActivityDetail?, settled: Bool, background: Int, tool: String?,
        quietSince: Date? = nil, fallback: LiveActivityFace
    ) -> LiveActivityLook {
        let symbol = detail?.face(tool: settled ? nil : tool).symbol ?? fallback.symbol
        let tone = detail?.face(tool: settled ? nil : tool).tone ?? fallback.tone
        guard let detail else {
            let state: WallState =
                settled ? .finished(fallback.tone == .danger ? .failed : .done) : .working
            return LiveActivityLook(
                state: state, mark: settled ? (fallback.tone == .danger ? .cross : .check) : .orb,
                symbol: symbol, tone: tone)
        }
        if !settled, !detail.wantsYou, let quietSince {
            return LiveActivityLook(
                state: .quiet(since: quietSince), mark: .quiet, symbol: symbol, tone: .quiet)
        }
        let state: WallState
        let mark: Mark
        switch detail {
        case .thinking:
            (state, mark) = (.thinking, .orb)
        case .writing, .tool, .compacting:
            (state, mark) = (.working, .orb)
        case .question, .approval:
            (state, mark) = (.needsYou(.fresh), .ask)
        case .finished:
            (state, mark) = background > 0 ? (.background(stuck: false), .background) : (.finished(.done), .check)
        case .answerless, .lost:
            (state, mark) = (.finished(.unknown), .unknown)
        case .failed, .noResponse, .sendFailed, .interrupted:
            (state, mark) = (.finished(.failed), .cross)
        case .cancelled:
            (state, mark) = (.finished(.stopped), .stop)
        }
        return LiveActivityLook(state: state, mark: mark, symbol: symbol, tone: tone)
    }

    /// The word beside the mark, the wall's own for the state.
    public var word: String {
        switch state {
        case .working: return Localized.text("Working")
        case .thinking: return Localized.text("Thinking")
        case .needsYou: return Localized.text("Needs you")
        case .retrying: return Localized.text("Retrying")
        case .quiet: return Localized.text("Nothing new")
        case .background(let stuck): return stuck ? Localized.text("stuck") : Localized.text("in the background")
        case .finished(let outcome):
            switch outcome {
            case .done: return Localized.text("Done")
            case .failed: return Localized.text("Failed")
            case .stopped: return Localized.text("Stopped")
            case .unknown: return Localized.text("Finished")
            }
        case .away: return Localized.text("Away")
        }
    }
}

/// When a live card admits nothing has moved: the wall's own threshold, read off the moment the
/// card was last seen to move, so the platform can be told to redraw it then.
public enum LiveActivityQuiet {
    public static let after: TimeInterval = 45

    public static func since(moved: Date?, now: Date) -> Date? {
        guard let moved, now.timeIntervalSince(moved) >= after else { return nil }
        return moved
    }

    /// When a live card should next be redrawn as quiet if nothing reaches it first.
    public static func staleDate(moved: Date?, now: Date, ceiling: TimeInterval) -> Date {
        let quiet = (moved ?? now).addingTimeInterval(after)
        return min(max(quiet, now.addingTimeInterval(1)), now.addingTimeInterval(ceiling))
    }
}

/// The words a card leads with, the wall's own: what the agent is doing in plain words while it
/// works, what it waits on while it waits, and how the turn went once it ended.
public enum LiveActivityHeadline {
    /// The card's large line. `statusText` is what a card from before the detail key carries.
    public static func line(
        detail: LiveActivityDetail?, statusText: String, brief: LiveActivityBrief?, tool: String?,
        toolCount: Int, background: Int, settled: Bool
    ) -> String {
        guard let detail else { return statusText }
        if settled {
            switch detail {
            case .finished:
                var line = AgentFinish.line(
                    outcome: .done, duration: nil, tools: toolCount, files: brief?.files ?? 0)
                if background > 0 { line += " · " + Localized.text("%lld tasks still running", background) }
                return line
            default:
                return detail.line(tool: nil, toolCount: toolCount, background: background)
            }
        }
        switch detail {
        case .thinking: return Localized.text("Thinking")
        case .writing: return Localized.text("Writing the answer")
        case .compacting: return Localized.text("Tidying up the conversation to free room")
        case .tool:
            if let step = said(brief: brief, detail: detail, settled: false) { return step.words }
            return detail.line(tool: tool, toolCount: toolCount, background: background)
        default:
            return detail.line(tool: tool, toolCount: toolCount, background: background)
        }
    }

    /// The small capitals over what a turn waits on: the command an approval would run, or the
    /// question; nil for anything that is not waiting on the person.
    public static func askLead(_ detail: LiveActivityDetail?) -> String? {
        switch detail {
        case .approval?: return Localized.text("Wants to run")
        case .question?: return Localized.text("Asks")
        default: return nil
        }
    }

    /// The step the line says: the latest one still out while a tool runs.
    public static func said(
        brief: LiveActivityBrief?, detail: LiveActivityDetail?, settled: Bool
    ) -> LiveActivityStep? {
        guard !settled, detail == .tool else { return nil }
        return brief?.steps?.last(where: \.isRunning)
    }

    /// The steps listed under the line, newest first: the one the line already says is left out.
    public static func listed(
        brief: LiveActivityBrief?, detail: LiveActivityDetail?, settled: Bool, limit: Int
    ) -> [LiveActivityStep] {
        guard limit > 0, var steps = brief?.steps, !steps.isEmpty else { return [] }
        if let shown = said(brief: brief, detail: detail, settled: settled) {
            steps.removeAll { $0.id == shown.id }
        }
        return Array(steps.reversed().prefix(limit))
    }
}

/// Which running conversations get a card while the app is in front, for the turns this device
/// did not send. A turn waiting on the person comes first, then the one that moved last; a muted
/// chat, one already followed and one past `limit` cards standing get none.
public enum LiveActivityFollow {
    public struct Candidate: Sendable, Equatable {
        public let sessionID: String
        public let movedAt: Date
        public let waitsOnYou: Bool

        public init(sessionID: String, movedAt: Date, waitsOnYou: Bool = false) {
            self.sessionID = sessionID
            self.movedAt = movedAt
            self.waitsOnYou = waitsOnYou
        }
    }

    /// The most cards the app keeps standing at once for turns it follows by itself.
    public static let limit = 4

    public static func choose(
        _ running: [Candidate], following: Set<String>, muted: Set<String>, standing: Int,
        limit: Int = LiveActivityFollow.limit
    ) -> [String] {
        let room = max(0, limit - standing)
        guard room > 0 else { return [] }
        var seen = Set<String>()
        return running
            .filter { !following.contains($0.sessionID) && !muted.contains($0.sessionID) }
            .filter { seen.insert($0.sessionID).inserted }
            .sorted { lhs, rhs in
                if lhs.waitsOnYou != rhs.waitsOnYou { return lhs.waitsOnYou }
                return lhs.movedAt > rhs.movedAt
            }
            .prefix(room)
            .map(\.sessionID)
    }
}
