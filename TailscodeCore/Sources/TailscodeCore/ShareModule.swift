import Foundation

/// The picture a share is made for. `post` is the one X shows whole in a timeline, so it is the
/// default; `long` is the full-length column the card has always been, kept for people who share
/// it somewhere a tall picture is welcome. Sizes are logical points; clients rasterise at 2×.
public enum ShareFormat: String, CaseIterable, Sendable, Codable {
    case post
    case square
    case portrait
    case long

    public static let storageKey = "tailscode.shareFormat"
    public static let fallback = ShareFormat.post

    public var title: String {
        switch self {
        case .post: return Localized.text("Post")
        case .square: return Localized.text("Square")
        case .portrait: return Localized.text("Portrait")
        case .long: return Localized.text("Full length")
        }
    }

    /// One line on what the format is for, for a tooltip or a menu with room for it.
    public var tagline: String {
        switch self {
        case .post: return Localized.text("Fills X's timeline, nothing cropped")
        case .square: return Localized.text("Square, fits anywhere")
        case .portrait: return Localized.text("4:5, the tallest X shows whole")
        case .long: return Localized.text("Every module in one tall column")
        }
    }

    public var symbolName: String {
        switch self {
        case .post: return "rectangle"
        case .square: return "square"
        case .portrait: return "rectangle.portrait"
        case .long: return "rectangle.portrait.tophalf.inset.filled"
        }
    }

    public var canvasWidth: Double {
        switch self {
        case .post: return 1600
        case .square, .portrait, .long: return 1080
        }
    }

    /// The height every canvas of this format has; nil for the one whose height is its content.
    public var canvasHeight: Double? {
        switch self {
        case .post: return 900
        case .square: return 1080
        case .portrait: return 1350
        case .long: return nil
        }
    }

    /// How many modules the picture holds before it stops being a poster. The full-length column
    /// has no limit; it grows.
    public var capacity: Int? {
        switch self {
        case .post, .square: return 4
        case .portrait: return 6
        case .long: return nil
        }
    }

    /// The modules a format opens with before anyone has chosen: a short, strong set for a
    /// poster, and for the column exactly what the card showed before it was modular.
    public var curated: [ShareModule] {
        switch self {
        case .post, .square: return [.daily, .models, .tokens, .records]
        case .portrait: return [.activity, .daily, .week, .models, .tokens, .records]
        case .long:
            return [
                .activity, .daily, .week, .providers, .models, .projects, .tools, .records,
                .insights,
            ]
        }
    }
}

/// One section of the picture a person can switch on or off. The headline number, the window and
/// the trend are not a module: every picture opens with them (``hero``), so there is nothing to
/// choose and nothing to leave out.
public enum ShareModule: String, CaseIterable, Sendable, Codable {
    case hero
    case activity
    case daily
    case week
    case providers
    case models
    case projects
    case tools
    case tokens
    case records
    case insights

    /// The modules a person chooses between, in the one order they are always drawn in.
    public static let selectable: [ShareModule] = allCases.filter(\.isSelectable)

    /// What survives when a format holds fewer modules than were asked for: the first of these
    /// are kept. The order is what a stranger scrolling a timeline stops for — the shape of the
    /// month, the models, the records — before the detail that explains it.
    public static let priority: [ShareModule] = [
        .daily, .models, .records, .tokens, .activity, .week, .providers, .projects, .tools,
        .insights,
    ]

    public var isSelectable: Bool { self != .hero }

    /// The word on the chip that switches it.
    public var title: String {
        switch self {
        case .hero: return Localized.text("Total")
        case .activity: return Localized.text("Activity")
        case .daily: return Localized.text("Over time")
        case .week: return Localized.text("Week")
        case .models: return Localized.text("Models")
        case .providers: return Localized.text("Providers")
        case .projects: return Localized.text("Projects")
        case .tools: return Localized.text("Tools")
        case .tokens: return Localized.text("Tokens")
        case .records: return Localized.text("Records")
        case .insights: return Localized.text("Insights")
        }
    }

    /// An SF Symbol name; a client without symbols maps it to its own icon set.
    public var symbolName: String {
        switch self {
        case .hero: return "sum"
        case .activity: return "bolt.fill"
        case .daily: return "chart.bar.fill"
        case .week: return "calendar"
        case .models: return "cpu"
        case .providers: return "server.rack"
        case .projects: return "folder"
        case .tools: return "wrench.and.screwdriver"
        case .tokens: return "circle.grid.2x2"
        case .records: return "trophy"
        case .insights: return "sparkles"
        }
    }

    /// Whether the account has anything to put in this module. A module that has not is shown to
    /// the person disabled, with ``unavailableReason(in:)``, and never silently missing.
    public func isAvailable(in analytics: UsageAnalytics) -> Bool {
        switch self {
        case .hero, .activity: return true
        case .daily: return analytics.days.contains { $0.share > 0 }
        case .week: return analytics.weekdays.contains { $0.share > 0 }
        case .models: return !analytics.models.isEmpty
        case .providers: return !analytics.providers.isEmpty
        case .projects: return !analytics.projects.isEmpty
        case .tools: return !analytics.tools.isEmpty
        case .tokens: return analytics.tiers.contains { $0.tokens > 0 }
        case .records: return !analytics.records.isEmpty
        case .insights: return !AnalyticsShare.standouts(analytics).isEmpty
        }
    }

    /// Why the module is not on offer, in the words a tooltip shows; nil while it is available.
    public func unavailableReason(in analytics: UsageAnalytics) -> String? {
        guard !isAvailable(in: analytics) else { return nil }
        switch self {
        case .hero, .activity: return nil
        case .daily, .week: return Localized.text("No activity in this window")
        case .models: return Localized.text("No model usage in this window")
        case .providers: return Localized.text("All the work went through one provider")
        case .projects: return Localized.text("No project in this window")
        case .tools: return Localized.text("No server counted tool calls")
        case .tokens: return Localized.text("No token counts in this window")
        case .records: return Localized.text("No records yet")
        case .insights: return Localized.text("Nothing stands out yet")
        }
    }

    /// The smallest panel, in points, the module is laid out in for a format. Packing never gives
    /// a module less; a format's grid is chosen so that every tile it makes is at least this.
    public struct Footprint: Sendable, Equatable {
        public let width: Double
        public let height: Double
    }

    public func footprint(in format: ShareFormat) -> Footprint {
        let rows: Double
        switch self {
        case .hero: return Footprint(width: 480, height: 300)
        case .activity: rows = 2
        case .daily, .week: rows = 2.4
        case .models, .providers, .projects, .tools, .tokens, .records: rows = 2
        case .insights: rows = 2
        }
        let unit = format == .post ? 1.2 : 1.1
        return Footprint(width: 360 * unit, height: (38 + rows * 54) * unit)
    }
}

/// What a person asked for and what the picture will actually hold. A format has room for only so
/// many modules and an account does not have data for every one of them; this says, in one
/// place, which are drawn, which were left out for room and which could not be drawn at all, so
/// a client never has to work it out or leave the person guessing.
public struct ShareFit: Sendable, Equatable {
    public enum ChipState: Sendable, Equatable {
        case on
        case off
        case blocked(String)
    }

    public let format: ShareFormat
    public let shown: [ShareModule]
    public let dropped: [ShareModule]
    public let unavailable: [ShareModule: String]

    /// The sentence under the module row when the format could not hold everything asked for.
    public var note: String? {
        guard !dropped.isEmpty, let capacity = format.capacity else { return nil }
        return Localized.text(
            "%1$@ holds %2$d modules. Left out: %3$@", format.title, capacity,
            dropped.map(\.title).joined(separator: ", "))
    }

    public var isFull: Bool {
        guard let capacity = format.capacity else { return false }
        return shown.count >= capacity
    }

    /// How a module's chip reads: lit, off, or off and not to be pressed because there is nothing
    /// to put in it or no room left for it.
    public func state(of module: ShareModule) -> ChipState {
        if shown.contains(module) { return .on }
        if let reason = unavailable[module] { return .blocked(reason) }
        if isFull, let capacity = format.capacity {
            return .blocked(
                Localized.text(
                    "%1$@ holds %2$d modules. Turn one off to add another.", format.title,
                    capacity))
        }
        return .off
    }
}

/// The whole of a share choice: which picture, which modules in it, which look. Each format keeps
/// its own modules, because a column and a poster want different things and changing one must not
/// rearrange the other; a format nobody has touched wears its curated set.
public struct ShareSelection: Sendable, Equatable {
    public var format: ShareFormat
    public var style: CardStyle
    public private(set) var chosen: [ShareFormat: [ShareModule]]

    public init(
        format: ShareFormat = .fallback, style: CardStyle? = nil,
        chosen: [ShareFormat: [ShareModule]] = [:]
    ) {
        self.format = format
        self.style = style ?? CardStyleSelection.defaultStyle(for: format)
        self.chosen = chosen.mapValues(Self.canonical)
    }

    /// The modules asked for in the current format, whether or not the account can fill them.
    public var requested: [ShareModule] { chosen[format] ?? format.curated }

    /// Whether the person has changed this format's modules, or it still wears its curated set.
    public var isCustomised: Bool { chosen[format] != nil }

    public static func canonical(_ modules: [ShareModule]) -> [ShareModule] {
        let wanted = Set(modules)
        return ShareModule.selectable.filter(wanted.contains)
    }

    /// What the picture holds for an account. A set the person chose is honoured as chosen, less
    /// what the account cannot fill and, if it is more than the format holds, what ranks last
    /// (``ShareModule/priority``). A curated set is filled up to the format's capacity from the
    /// modules the account does have, so a thin account still gets a full poster.
    public func fit(_ analytics: UsageAnalytics) -> ShareFit {
        let asked = requested
        var unavailable: [ShareModule: String] = [:]
        for module in ShareModule.selectable {
            if let reason = module.unavailableReason(in: analytics) { unavailable[module] = reason }
        }
        var usable = asked.filter { unavailable[$0] == nil }
        if !isCustomised, let capacity = format.capacity, usable.count < capacity {
            for module in ShareModule.priority
            where usable.count < capacity && unavailable[module] == nil && !usable.contains(module) {
                usable.append(module)
            }
        }
        var dropped: [ShareModule] = []
        if let capacity = format.capacity, usable.count > capacity {
            let keep = Set(ShareModule.priority.filter(usable.contains).prefix(capacity))
            dropped = Self.canonical(usable.filter { !keep.contains($0) })
            usable = usable.filter(keep.contains)
        }
        return ShareFit(
            format: format, shown: Self.canonical(usable), dropped: dropped,
            unavailable: unavailable)
    }

    public enum Toggle: Sendable, Equatable {
        case added
        case removed
        case refused(String)
    }

    /// Switches a module. From the first press a format's set is explicit: it starts from what
    /// the picture shows now, so pressing one chip changes one thing. Pressing a module the
    /// account cannot fill, or one more than the format holds, changes nothing and says why.
    @discardableResult
    public mutating func toggle(_ module: ShareModule, in analytics: UsageAnalytics) -> Toggle {
        guard module.isSelectable else { return .refused(ShareModule.hero.title) }
        let current = fit(analytics)
        switch current.state(of: module) {
        case .blocked(let reason): return .refused(reason)
        case .on:
            chosen[format] = current.shown.filter { $0 != module }
            return .removed
        case .off:
            chosen[format] = Self.canonical(current.shown + [module])
            return .added
        }
    }

    public mutating func forgetChoices(for format: ShareFormat) {
        chosen[format] = nil
    }

    private static let formatSeparator = ";"
    private static let moduleSeparator = ","
    private static let assign = "="

    /// The per-format sets as one string for a single defaults key, `post=daily,models;long=…`.
    public var encodedChoices: String {
        ShareFormat.allCases.compactMap { format in
            chosen[format].map {
                format.rawValue + Self.assign + $0.map(\.rawValue).joined(separator: Self.moduleSeparator)
            }
        }.joined(separator: Self.formatSeparator)
    }

    /// Reads ``encodedChoices`` back. A format or module this build does not know is dropped
    /// rather than failing the rest, so a settings file written by a newer build still opens.
    public static func decodeChoices(_ text: String?) -> [ShareFormat: [ShareModule]] {
        var out: [ShareFormat: [ShareModule]] = [:]
        for entry in (text ?? "").split(separator: Character(formatSeparator)) {
            let pair = entry.split(
                separator: Character(assign), maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, let format = ShareFormat(rawValue: String(pair[0])) else {
                continue
            }
            out[format] = pair[1].split(separator: Character(moduleSeparator))
                .compactMap { ShareModule(rawValue: String($0)) }.filter(\.isSelectable)
        }
        return out
    }
}

/// Where the share choice is remembered on this device: the format, and each format's modules.
/// The look is `CardStyleSelection`'s, as it has always been.
public enum ShareSelectionStore {
    public static let modulesKey = "tailscode.shareModules"

    public static func load(defaults: UserDefaults = .standard) -> ShareSelection {
        let format =
            ShareFormat(rawValue: defaults.string(forKey: ShareFormat.storageKey) ?? "")
            ?? .fallback
        return ShareSelection(
            format: format, style: CardStyleSelection.current(for: format, defaults: defaults),
            chosen: ShareSelection.decodeChoices(defaults.string(forKey: modulesKey)))
    }

    public static func save(_ selection: ShareSelection, defaults: UserDefaults = .standard) {
        defaults.set(selection.format.rawValue, forKey: ShareFormat.storageKey)
        let encoded = selection.encodedChoices
        if encoded.isEmpty {
            defaults.removeObject(forKey: modulesKey)
        } else {
            defaults.set(encoded, forKey: modulesKey)
        }
    }
}
