import CodingAgentKit
import Foundation

/// Which capability on which machine a checklist is about.
public struct SetupTarget: Sendable, Hashable {
    public let host: String
    public let port: Int?
    public let capability: String

    public init(host: String, port: Int? = nil, capability: String) {
        self.host = host
        self.port = port
        self.capability = capability
    }

    public static func voice(_ endpoint: VoiceEndpoint) -> SetupTarget {
        SetupTarget(host: endpoint.host, port: endpoint.port, capability: SetupCapability.voice)
    }

    public static func media(_ endpoint: ForgeEndpoint) -> SetupTarget {
        SetupTarget(host: endpoint.host, port: endpoint.port, capability: SetupCapability.media)
    }

    /// The renderer a media target names, or nil for any other capability.
    public var forgeEndpoint: ForgeEndpoint? {
        guard capability == SetupCapability.media, !host.isEmpty else { return nil }
        return ForgeEndpoint(host: host, port: port ?? ForgeEndpoint.defaultPort)
    }

    public var isDemo: Bool { VoiceDemo.isDemoHost(host) }
}

/// What a fix on a row asks of the person: press a button for a job the machine does, or copy the
/// one command that needs their own rights.
public struct SetupRowFix: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case job
        case command
    }

    public let id: String
    public let kind: Kind
    public let label: String
    public let cost: String?
    public let command: String?
    public let reason: String?
    public let enabled: Bool

    public init(
        id: String, kind: Kind, label: String, cost: String? = nil, command: String? = nil, reason: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.cost = cost
        self.command = command
        self.reason = reason
        self.enabled = enabled
    }

    func disabled() -> SetupRowFix {
        SetupRowFix(id: id, kind: kind, label: label, cost: cost, command: command, reason: reason, enabled: false)
    }
}

/// A job a row is following: how far, in words, and whether it can be stopped.
public struct SetupRowJob: Sendable, Equatable {
    public let id: String
    public let fixID: String
    public let fraction: Double?
    public let line: String?
    public let step: String?
    public let waiting: Bool

    public init(id: String, fixID: String, fraction: Double?, line: String?, step: String?, waiting: Bool) {
        self.id = id
        self.fixID = fixID
        self.fraction = fraction
        self.line = line
        self.step = step
        self.waiting = waiting
    }
}

/// One line of the checklist. Its face is in the activity vocabulary: work breathes, everything
/// settled holds perfectly still, and the tone says who has to act.
public struct SetupRow: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case done
        case todo
        case working
        case needsYou
        case failed
        case unavailable
    }

    public let id: String
    public let state: State
    public let title: String
    public let line: String?
    public let fix: SetupRowFix?
    public let job: SetupRowJob?
    public let failure: String?
    public let optional: Bool

    public init(
        id: String, state: State, title: String, line: String?, fix: SetupRowFix? = nil,
        job: SetupRowJob? = nil, failure: String? = nil, optional: Bool = false
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.line = line
        self.fix = fix
        self.job = job
        self.failure = failure
        self.optional = optional
    }

    func withFix(_ next: SetupRowFix?) -> SetupRow {
        SetupRow(
            id: id, state: state, title: title, line: line, fix: next, job: job, failure: failure,
            optional: optional)
    }

    /// Whether the checklist is waiting on this row: something still to do that the person has not
    /// been told is optional, and not a thing this machine can never do.
    public var isBlocking: Bool {
        switch state {
        case .done, .unavailable: return false
        case .todo, .working, .needsYou, .failed: return !optional
        }
    }

    public var icon: ActivityIcon {
        switch state {
        case .done:
            return ActivityIcon(symbol: "checkmark.circle.fill", glyph: "✓", tone: .live, motion: .still)
        case .todo:
            return ActivityIcon(symbol: "circle.dashed", glyph: "○", tone: .quiet, motion: .still)
        case .working:
            return ActivityIcon(symbol: "arrow.down.circle.fill", glyph: "●", tone: .live, motion: .working)
        case .needsYou:
            return ActivityIcon(symbol: "exclamationmark.circle.fill", glyph: "!", tone: .attention, motion: .still)
        case .failed:
            return ActivityIcon(symbol: "exclamationmark.triangle", glyph: "✗", tone: .danger, motion: .still)
        case .unavailable:
            return ActivityIcon(symbol: "nosign", glyph: "⊘", tone: .quiet, motion: .still)
        }
    }

    public var word: String {
        switch state {
        case .done: return Localized.text("Done")
        case .todo: return Localized.text("To do")
        case .working: return Localized.text("Working")
        case .needsYou: return Localized.text("Needs you")
        case .failed: return Localized.text("Failed")
        case .unavailable: return Localized.text("Not possible")
        }
    }

    public var spoken: String {
        [title, word, line, failure].compactMap { $0 }.joined(separator: ". ")
    }
}

/// The one button at the foot of a checklist. There is only ever one, because a checklist that offers
/// three roads has not decided which one is next.
public enum SetupAction: Sendable, Equatable {
    case setUp(label: String)
    case copy(command: String, label: String)
    case finish(label: String)
    case askPassword(label: String)

    public var label: String {
        switch self {
        case .setUp(let label), .finish(let label), .askPassword(let label): return label
        case .copy(_, let label): return label
        }
    }
}

/// What a checklist is, as a whole: a headline with a tone, and which of the few states it is in.
public enum SetupStatus: Sendable, Equatable {
    case checking
    case ready
    case needs(Int)
    case working
    case unavailable
    case unreachable
    case wantsPassword
}

/// Everything a client draws of one capability on one machine, and nothing it has to decide: rows with
/// their glyphs and fixes, the headline, the single primary action, and the honest state of a machine
/// that can never do this. It is a value; a client rebuilds its view from it whenever it changes.
public struct SetupChecklist: Sendable, Equatable {
    public let target: SetupTarget
    public let name: String
    public let beta: BetaFeature?
    public let status: SetupStatus
    public let headline: String
    public let tone: ActivityTone
    public let rows: [SetupRow]
    public let primary: SetupAction?
    public let canCancel: Bool
    public let unavailable: Bool
    public let focus: SetupFocus?
    public let place: SetupPlace?

    public init(
        target: SetupTarget, name: String, beta: BetaFeature?, status: SetupStatus, headline: String,
        tone: ActivityTone, rows: [SetupRow], primary: SetupAction?, canCancel: Bool = false,
        unavailable: Bool = false, focus: SetupFocus? = nil, place: SetupPlace? = nil
    ) {
        self.target = target
        self.name = name
        self.beta = beta
        self.status = status
        self.headline = headline
        self.tone = tone
        self.rows = rows
        self.primary = primary
        self.canCancel = canCancel
        self.unavailable = unavailable
        self.focus = focus
        self.place = place
    }

    public var isReady: Bool { status == .ready }

    public var icon: ActivityIcon {
        switch status {
        case .ready:
            return ActivityIcon(symbol: "checkmark.circle.fill", glyph: "✓", tone: .live, motion: .still)
        case .working:
            return ActivityIcon(symbol: "arrow.down.circle.fill", glyph: "●", tone: .live, motion: .working)
        case .checking:
            return ActivityKind.connecting.icon
        case .needs, .wantsPassword:
            return ActivityIcon(symbol: "exclamationmark.circle.fill", glyph: "!", tone: .attention, motion: .still)
        case .unreachable:
            return ActivityIcon(symbol: "wifi.slash", glyph: "⚠", tone: .attention, motion: .still)
        case .unavailable:
            return ActivityIcon(symbol: "nosign", glyph: "⊘", tone: .quiet, motion: .still)
        }
    }

    public var spoken: String { ([name, headline] + rows.map(\.spoken)).joined(separator: ". ") }

    public var jobRow: SetupRow? { rows.first { $0.job != nil } }
}

extension SetupChecklist {
    public static func headline(forWorking phrase: String, fraction: Double?, locale: Locale = .current) -> String {
        guard let fraction else { return Localized.text("Working: %@", phrase) }
        return Localized.text("Working: %1$@, %2$@", phrase, SetupFormat.percent(fraction, locale: locale))
    }

    public static func headline(forNeeding count: Int, locale: Locale = .current) -> String {
        count <= 1
            ? Localized.text("Needs one thing")
            : Localized.text("Needs %@ things", SetupFormat.number(Double(count), locale: locale))
    }

    public static func headline(forImpossible reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return Localized.text("Not possible on this machine") }
        return Localized.text("Not possible on this machine: %@", reason)
    }
}

extension SetupChecklist {
    public init(snapshot: SetupSnapshot, locale: Locale = .current, focus: SetupFocus? = nil) {
        self = Self.make(snapshot: snapshot, locale: locale, focus: focus)
    }

    private static func make(snapshot: SetupSnapshot, locale: Locale, focus: SetupFocus?) -> SetupChecklist {
        let target = snapshot.target
        let reader = SetupReaders.shared.reader(for: target.capability)
        let name = SetupReading.name(of: target.capability)
        let beta = reader?.beta
        let place = reader?.place(of: target)
        func plain(_ status: SetupStatus, _ headline: String, _ tone: ActivityTone, _ primary: SetupAction? = nil)
            -> SetupChecklist
        {
            SetupChecklist(
                target: target, name: name, beta: beta, status: status, headline: headline, tone: tone, rows: [],
                primary: primary, focus: focus, place: place)
        }
        switch snapshot.phase {
        case .unreachable(let why):
            return plain(.unreachable, Localized.text("Could not reach this machine: %@", why), .attention)
        case .wantsPassword:
            return plain(
                .wantsPassword, VoiceReach.wantsPassword.line, .attention,
                .askPassword(label: Localized.text("Add the password")))
        default:
            break
        }
        guard let report = snapshot.report else {
            return plain(.checking, Localized.text("Checking this machine…"), .quiet)
        }
        return build(
            report: report, snapshot: snapshot, reader: reader, name: name, beta: beta, place: place,
            focus: focus, locale: locale)
    }

    private static func build(
        report: SetupReport, snapshot: SetupSnapshot, reader: (any SetupCapabilityReader)?, name: String,
        beta: BetaFeature?, place: SetupPlace?, focus: SetupFocus?, locale: Locale
    ) -> SetupChecklist {
        let target = snapshot.target
        let followed = snapshot.job ?? report.job
        let checks = report.available ? (reader?.arrange(report.checks, focus: focus) ?? report.checks) : report.checks
        let built = checks.map { row(for: $0, snapshot: snapshot, job: followed, locale: locale) }
        let busy = built.contains { $0.job != nil }
        let rows = built.map { busy && $0.job == nil && $0.fix?.kind == .job ? $0.withFix($0.fix?.disabled()) : $0 }
        let open = rows.filter(\.isBlocking)

        func result(_ status: SetupStatus, _ headline: String, _ tone: ActivityTone, _ primary: SetupAction?)
            -> SetupChecklist
        {
            SetupChecklist(
                target: target, name: name, beta: beta, status: status, headline: headline, tone: tone, rows: rows,
                primary: primary, canCancel: rows.contains { $0.job != nil }, unavailable: !report.available,
                focus: focus, place: place)
        }

        if !report.available {
            let reason = report.checks.first { $0.state == .unavailable }
                .flatMap { SetupReading.impossibility(of: $0, locale: locale) }
            return result(.unavailable, headline(forImpossible: reason), .quiet, nil)
        }
        if let job = rows.compactMap(\.job).first {
            let phrase = SetupReading.jobPhrase(of: job.fixID)
            return result(.working, headline(forWorking: phrase, fraction: job.fraction, locale: locale), .live, nil)
        }
        if open.isEmpty && (report.ready || !rows.isEmpty) {
            return result(
                .ready, reader?.readyHeadline(rows: rows, focus: focus) ?? Localized.text("%@ is ready", name), .live,
                .finish(label: reader?.readyActionLabel(focus: focus) ?? Localized.text("Done")))
        }
        let told = reader?.headline(blocking: open, focus: focus)
        if open.contains(where: { $0.state == .working }) {
            return result(.working, told ?? Localized.text("Working on it…"), .live, nil)
        }
        let count = max(1, open.count)
        return result(
            .needs(count), told ?? headline(forNeeding: count, locale: locale), .attention,
            primary(rows: open, snapshot: snapshot, reader: reader))
    }

    private static func primary(rows: [SetupRow], snapshot: SetupSnapshot, reader: (any SetupCapabilityReader)?)
        -> SetupAction?
    {
        guard let first = rows.first else { return nil }
        guard let fix = first.fix else { return nil }
        switch fix.kind {
        case .command:
            guard let command = fix.command, !command.isEmpty else { return nil }
            return .copy(command: command, label: Localized.text("Copy command"))
        case .job:
            let label = first.state == .failed ? Localized.text("Try again") : (reader?.setUpLabel ?? Localized.text("Set up"))
            return .setUp(label: label)
        }
    }

    private static func row(for check: SetupCheck, snapshot: SetupSnapshot, job: SetupJob?, locale: Locale) -> SetupRow {
        let title = SetupReading.title(of: check)
        var line = SetupReading.line(of: check, locale: locale)
        let fix = check.fix.map { rowFix($0, in: check, capability: snapshot.target.capability, locale: locale) }
        let optional = check.facts["optional"] != nil
        let mine = job.flatMap { Self.owns(check, $0) ? $0 : nil }
        if let mine, !mine.state.isSettled {
            let face = SetupRowJob(
                id: mine.id, fixID: mine.fix, fraction: mine.fraction.map { min(max($0, 0), 1) },
                line: SetupReading.jobLine(mine, eta: snapshot.eta, locale: locale),
                step: SetupReading.step(mine.step), waiting: mine.state == .queued)
            return SetupRow(id: check.id, state: .working, title: title, line: line, fix: fix, job: face)
        }
        if check.state == .ok { return SetupRow(id: check.id, state: .done, title: title, line: line, optional: optional) }
        if check.state == .unavailable {
            return SetupRow(id: check.id, state: .unavailable, title: title, line: line, optional: optional)
        }
        if check.state == .working {
            return SetupRow(id: check.id, state: .working, title: title, line: line, optional: optional)
        }
        let failed = [snapshot.failed, job].compactMap { $0 }.first { Self.owns(check, $0) && $0.state == .failed }
        if let failed {
            return SetupRow(
                id: check.id, state: .failed, title: title, line: line, fix: fix,
                failure: SetupReading.failure(of: failed, locale: locale))
        }
        if check.state == .todo, let last = check.facts["lastFailure"] {
            let earlier = SetupJob(id: check.facts["lastJob"] ?? "", fix: check.fix?.id ?? "", state: .failed, failure: last)
            return SetupRow(
                id: check.id, state: .failed, title: title, line: line, fix: fix,
                failure: SetupReading.failure(of: earlier, locale: locale))
        }
        if line == nil { line = SetupReading.neutral(check.state) }
        let waiting = check.state == .todo && fix == nil && check.facts["after"] != nil
        let needsYou = !waiting && (check.state == .blocked || fix == nil || fix?.kind == .command)
        return SetupRow(
            id: check.id, state: needsYou ? .needsYou : .todo, title: title, line: line, fix: fix,
            optional: optional)
    }

    /// Whether a job is the one a check is waiting on. A check that is working has no fix left to point
    /// at, so the machine names the job in its facts instead; one still to do names it by its fix.
    private static func owns(_ check: SetupCheck, _ job: SetupJob) -> Bool {
        if check.facts["job"] == job.id { return true }
        return check.fix?.id == job.fix
    }

    private static func rowFix(_ fix: SetupFix, in check: SetupCheck, capability: String, locale: Locale) -> SetupRowFix {
        SetupRowFix(
            id: fix.id, kind: fix.kind == .command ? .command : .job,
            label: SetupReading.fixLabel(of: fix, capability: capability),
            cost: fix.kind == .job ? SetupReading.fixCost(of: fix, locale: locale) : nil,
            command: fix.kind == .command ? fix.command : nil,
            reason: fix.kind == .command ? SetupReading.fixReason(of: fix, in: check, capability: capability) : nil)
    }
}
