import Foundation

/// What the last launch left behind: whether it closed normally, how many panes it had and the
/// level it was at. Written with `cleanExit: false` at launch and flipped on every exit path, so a
/// freeze, a kill or a crash is read on the next launch as the unclean exit it was.
public struct LaunchLedger: Sendable, Equatable, Codable {
    public var launchID: String
    public var startedAt: Date
    public var cleanExit: Bool
    public var panes: Int
    public var level: Int
    /// Whether the launch before this one also ended unclean, so two in a row can be told apart
    /// from one.
    public var previousUnclean: Bool

    public init(
        launchID: String = UUID().uuidString, startedAt: Date = Date(), cleanExit: Bool = false,
        panes: Int = 0, level: Int = 0, previousUnclean: Bool = false
    ) {
        self.launchID = launchID
        self.startedAt = startedAt
        self.cleanExit = cleanExit
        self.panes = panes
        self.level = level
        self.previousUnclean = previousUnclean
    }

    private enum CodingKeys: String, CodingKey {
        case launchID, startedAt, cleanExit, panes, level, previousUnclean
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchID = try container.decode(String.self, forKey: .launchID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        cleanExit = try container.decode(Bool.self, forKey: .cleanExit)
        panes = try container.decodeIfPresent(Int.self, forKey: .panes) ?? 0
        level = try container.decodeIfPresent(Int.self, forKey: .level) ?? 0
        previousUnclean = try container.decodeIfPresent(Bool.self, forKey: .previousUnclean) ?? false
    }

    /// `launch.json`, next to the flight ring.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        FlightRing.directory(environment: environment).appendingPathComponent("launch.json")
    }

    /// The ledger at `url`; nil when there is none or it will not decode.
    public static func read(url: URL) -> LaunchLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(LaunchLedger.self, from: data)
    }

    /// Writes the ledger whole, atomically, so a kill mid-write leaves the previous one readable.
    public func write(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Starts a launch: reads what the last one left, writes this one as not yet closed, and hands
    /// back both. The previous ledger is what `RestorePlan.decide` reads.
    @discardableResult
    public static func begin(
        url: URL, panes: Int, level: Int = 0, now: Date = Date()
    ) -> (previous: LaunchLedger?, current: LaunchLedger) {
        let previous = read(url: url)
        let current = LaunchLedger(
            startedAt: now, cleanExit: false, panes: panes, level: level,
            previousUnclean: previous.map { !$0.cleanExit } ?? false)
        try? current.write(url: url)
        return (previous, current)
    }

    /// Records a normal exit of the launch `launchID`. A ledger written by another launch since is
    /// left alone.
    public static func markClean(url: URL, launchID: String, panes: Int? = nil, level: Int? = nil) {
        guard var ledger = read(url: url), ledger.launchID == launchID else { return }
        ledger.cleanExit = true
        if let panes { ledger.panes = panes }
        if let level { ledger.level = level }
        try? ledger.write(url: url)
    }
}

/// How a window comes back after a launch, decided before anything opens.
public struct RestorePlan: Sendable, Equatable {
    public static let uncleanParkThreshold = 3
    public static let wakeSpacing: TimeInterval = 0.3
    public static let repeatFloor = ShedLevel.loaded
    public static let repeatFloorDuration: TimeInterval = 600

    public enum Mode: Sendable, Equatable {
        /// Restore the shape at once and wake panes one after another.
        case staggered
        /// Restore the shape with every chat parked and the banner offering to resume them.
        case parked(bannerCount: Int)
    }

    public var mode: Mode
    /// The previous launch did not close normally.
    public var unclean: Bool
    /// The shed-level floor to hold, and for how long: two unclean exits in a row.
    public var floor: ShedLevel?
    public var floorDuration: TimeInterval

    public init(mode: Mode, unclean: Bool, floor: ShedLevel? = nil, floorDuration: TimeInterval = 0) {
        self.mode = mode
        self.unclean = unclean
        self.floor = floor
        self.floorDuration = floorDuration
    }

    /// - Parameters:
    ///   - ledger: what the previous launch left; nil on a first launch.
    ///   - paneCount: the chat panes the snapshot about to be restored holds.
    ///   - previousUnclean: whether the launch before that one also ended unclean.
    public static func decide(ledger: LaunchLedger?, paneCount: Int, previousUnclean: Bool) -> RestorePlan {
        guard let ledger, !ledger.cleanExit else { return RestorePlan(mode: .staggered, unclean: false) }
        let repeated = previousUnclean
        let mode: Mode =
            paneCount >= uncleanParkThreshold ? .parked(bannerCount: paneCount) : .staggered
        return RestorePlan(
            mode: mode, unclean: true, floor: repeated ? repeatFloor : nil,
            floorDuration: repeated ? repeatFloorDuration : 0)
    }

    /// The same decision, with the streak read from the ledger itself.
    public static func decide(ledger: LaunchLedger?, paneCount: Int) -> RestorePlan {
        decide(ledger: ledger, paneCount: paneCount, previousUnclean: ledger?.previousUnclean ?? false)
    }

    /// When each pane wakes after a restore, as offsets from the restore: the focused pane first,
    /// then the rest in most-recently-focused order, `spacing` apart, so a restore never opens N
    /// streams in one frame. Panes named twice wake once.
    public static func wakeSchedule(
        focused: PaneID?, recent: [PaneID], spacing: TimeInterval = wakeSpacing
    ) -> [(pane: PaneID, at: TimeInterval)] {
        var order: [PaneID] = []
        var seen = Set<PaneID>()
        for pane in [focused].compactMap({ $0 }) + recent where seen.insert(pane).inserted {
            order.append(pane)
        }
        return order.enumerated().map { ($0.element, Double($0.offset) * spacing) }
    }

    /// The banner's sentence for a parked restore.
    public var bannerText: String? {
        guard case .parked(let count) = mode else { return nil }
        return Localized.text(
            "Tailscode didn't close normally last time. %@ chats are paused.", String(count))
    }
}
