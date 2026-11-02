import Foundation

/// A week of every Pro feature, once per device, that a person starts themselves at the gate they just met: the second
/// server, Delegate, the Pro sheet. Nothing is charged and nothing renews. What it lends is honest about coming back: a
/// server added during the week rests once it is over (still saved, never deleted) until Pro is bought, and the person
/// chooses which server stays connected. Servers configured before the week are never taken away.
///
/// The calendar is derived from the start date alone, so a relaunch, a reinstall or a clock change all agree.
public enum ProWeek {
    public static let length: TimeInterval = 7 * 86_400

    public enum Phase: Equatable, Sendable {
        case notStarted
        case active(endsAt: Date)
        case ended(at: Date)

        public var isActive: Bool {
            if case .active = self { return true }
            return false
        }

        public var hasEnded: Bool {
            if case .ended = self { return true }
            return false
        }
    }

    /// A clock wound back before the start reads as the week's first moment, never as a week that has not begun.
    public static func phase(start: Date?, now: Date) -> Phase {
        guard let start else { return .notStarted }
        let end = start.addingTimeInterval(length)
        return max(0, now.timeIntervalSince(start)) < length ? .active(endsAt: end) : .ended(at: end)
    }

    /// Whole days left until `end`, counting a part day as a day, so the last day reads as the last day and never as zero.
    public static func daysLeft(until end: Date, now: Date) -> Int {
        max(1, Int((end.timeIntervalSince(now) / 86_400).rounded(.up)))
    }

    /// "Pro week · 5 days left", or "Pro week · last day" on the last one, which keeps every catalog line free of plurals.
    public static func daysLeftText(until end: Date, now: Date = Date()) -> String {
        let days = daysLeft(until: end, now: now)
        return days == 1 ? Localized.text("Pro week · last day") : Localized.text("Pro week · %lld days left", days)
    }

    /// "Saturday, November 9" in the person's language and calendar.
    public static func endDateText(_ end: Date) -> String {
        end.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    public static var offerTitle: String { Localized.text("Try every Pro feature free for a week") }

    /// What the week is, said before it starts: what it opens, that it costs nothing, and what happens after.
    public static var offerBody: String {
        Localized.text(
            "Unlimited servers, Delegate and every Live Activity, for seven days. Nothing is charged and nothing renews. Afterwards, servers you added rest until you get Pro; nothing is deleted.")
    }

    public static var startTitle: String { Localized.text("Start My Free Pro Week") }

    /// The line the Pro sheet leads with while the week runs.
    public static func runningLine(endsAt: Date) -> String {
        Localized.text("Your Pro week runs until %@. Get Pro to keep every server connected after that.", endDateText(endsAt))
    }

    public static var endedTitle: String { Localized.text("Your Pro week has ended") }

    /// The one note after the week: which server stays connected and which rest, or, with nothing resting, what went back.
    public static func endedBody(kept: [String], resting: [String]) -> String {
        guard !resting.isEmpty else {
            return Localized.text("Delegate and more than one Live Activity at a time are part of Tailscode Pro again.")
        }
        return Localized.text(
            "Connected: %1$@. Resting until you get Pro: %2$@. Nothing is deleted, and you can choose which server stays connected.",
            ListFormatter.localizedString(byJoining: kept), ListFormatter.localizedString(byJoining: resting))
    }

    public static var restingTitle: String { Localized.text("Resting") }

    public static var restingDetail: String { Localized.text("Resting until you get Pro. Nothing is deleted.") }

    public static var useInsteadTitle: String { Localized.text("Keep This Server Connected") }

    /// The choice when more than one server stays connected: which of them rests in its place.
    public static func useInsteadOf(_ name: String) -> String {
        Localized.text("Keep Connected Instead of %@", name)
    }

    public static var chooseServerTitle: String { Localized.text("Choose Server") }
}

/// Which saved servers stay connected and which rest. Nothing rests unless the week lent it: Pro, a week still running, a
/// week never started, or a week in which no server was added all leave every server connected. After the week the free
/// copy keeps as many servers as it had when the week began (at least `ProOffer.freeServerLimit`), chosen in this order:
/// the person's own picks, most recent first, then the servers that were already there, then the ones the week added, each
/// in the order they were saved. Deleting a connected server therefore wakes the next one rather than leaving none.
public enum ServerAllowance {
    public static func resting(
        saved: [String], lent: Set<String>, picks: [String], keeps: Int, isPro: Bool, phase: ProWeek.Phase
    ) -> Set<String> {
        guard !isPro, phase.hasEnded, saved.contains(where: lent.contains) else { return [] }
        let budget = max(ProOffer.freeServerLimit, keeps)
        let order = picks.filter(saved.contains)
            + saved.filter { !lent.contains($0) }
            + saved.filter(lent.contains)
        var connected: [String] = []
        for id in order where !connected.contains(id) && connected.count < budget {
            connected.append(id)
        }
        return Set(saved).subtracting(connected)
    }

    /// The picks after the person keeps `id` connected in place of `replacing`: `id` first, then every server connected
    /// now except `replacing`, so exactly the one asked for goes to rest.
    public static func keep(_ id: String, replacing: String, connected: [String]) -> [String] {
        [id] + connected.filter { $0 != id && $0 != replacing }
    }
}

/// The ids of the servers resting after the Pro week, written beside the saved profiles so an extension that reads those
/// profiles on its own (the Mac widget's usage fetch) leaves the resting ones alone too.
public enum RestingServersFile {
    public static let name = "resting-servers.json"

    public static func read(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    /// Writes the set, or removes the file when nothing rests, and leaves an unchanged file alone.
    public static func write(_ ids: Set<String>, in directory: URL) {
        let url = directory.appendingPathComponent(name)
        guard ids != read(in: directory) else { return }
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
