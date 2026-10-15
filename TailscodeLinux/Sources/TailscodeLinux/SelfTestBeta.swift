import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SelfTest {
    /// What the beta mark and its card promise that does not need a person looking: the freshness
    /// each seen-version reads as, which marks are announced by light and which hold still, the
    /// card's sections for each feature in order, the report's text, the seen-store surviving a
    /// reinstall through the settings file, the single pass of light running exactly once on its own
    /// frame clock and taking the clock off when it ends, and the parity answer.
    static func checkBeta() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("beta: \(label)") }
            checks += 1
        }
        let defaults = UserDefaults.standard
        let keys = BetaFeature.allCases.map(BetaSeenStore.key)
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in previous { SettingsFile.set(value, forKey: key) }
            SettingsFile.flush()
            for feature in BetaFeature.allCases { BetaBadge.forgetAnnouncement(of: feature) }
        }
        for key in keys { SettingsFile.set(nil, forKey: key) }
        for feature in BetaFeature.allCases { BetaBadge.forgetAnnouncement(of: feature) }

        try checkBetaFreshness(expect)
        try checkBetaCards(expect)
        try checkBetaReport(expect)
        try checkBetaSeenStore(expect)
        try checkBetaParity(expect)
        guard gtk_init_check() != 0 else { return checks }
        for key in keys { SettingsFile.set(nil, forKey: key) }
        try checkBetaBadge(expect)
        return checks
    }

    private static func checkBetaFreshness(_ expect: (Bool, String) throws -> Void) throws {
        let current = SoftwareVersion("1.80")!
        let plain = BetaFeature.delegate.card
        let changing = BetaCard(
            name: plain.name, symbol: plain.symbol, glyph: plain.glyph, title: plain.title,
            lead: plain.lead, paragraphs: plain.paragraphs, works: plain.works, rough: plain.rough,
            changes: [
                BetaChange(since: SoftwareVersion("1.78")!, line: "newer"),
                BetaChange(since: SoftwareVersion("1.70")!, line: "older"),
            ], reportName: plain.reportName)
        try expect(BetaFreshness.read(seen: nil, current: current, card: plain) == .unseen, "never opened reads unseen")
        try expect(BetaFreshness.read(seen: nil, current: current, card: changing) == .unseen, "never opened is unseen even with changes")
        try expect(
            BetaFreshness.read(seen: SoftwareVersion("1.60")!, current: current, card: plain) == .settled,
            "a card with nothing to say settles however old the view")
        try expect(
            BetaFreshness.read(seen: SoftwareVersion("1.75")!, current: current, card: changing) == .changed,
            "opened before the newest change reads changed")
        try expect(
            BetaFreshness.read(seen: SoftwareVersion("1.78")!, current: current, card: changing) == .settled,
            "opened at the newest change settles")
        try expect(
            BetaFreshness.read(seen: SoftwareVersion("1.75")!, current: SoftwareVersion("1.77")!, card: changing)
                == .settled,
            "a change newer than this build is not announced by it")

        try expect(BetaBadge.announces(.unseen, already: false, reducedMotion: false), "an unseen mark is announced")
        try expect(BetaBadge.announces(.changed, already: false, reducedMotion: false), "a changed mark is announced")
        try expect(!BetaBadge.announces(.settled, already: false, reducedMotion: false), "a settled mark holds still")
        try expect(!BetaBadge.announces(.unseen, already: true, reducedMotion: false), "a mark is announced once per process")
        try expect(!BetaBadge.announces(.changed, already: false, reducedMotion: true), "reduced motion draws no light")
        try expect(BetaSheen.progress(elapsed: BetaSheen.duration / 2, reducedMotion: false) != nil, "mid-pass the light is somewhere")
        try expect(BetaSheen.progress(elapsed: BetaSheen.duration / 2, reducedMotion: true) == nil, "reduced motion has no light mid-pass")
        try expect(BetaSheen.progress(elapsed: BetaSheen.duration + 0.1, reducedMotion: false) == nil, "after the pass nothing is drawn")
    }

    private static func checkBetaCards(_ expect: (Bool, String) throws -> Void) throws {
        for feature in BetaFeature.allCases {
            let card = feature.card
            for freshness in [BetaFreshness.unseen, .changed, .settled] {
                let blocks = BetaCardLayout.blocks(for: card, freshness: freshness)
                try expect(blocks.first == .title(card.title), "\(feature.rawValue): the card opens on its title")
                try expect(blocks.dropFirst().first == .lead(card.lead), "\(feature.rawValue): the lead follows")
                let hasSince = blocks.contains {
                    if case .since = $0 { return true }
                    return false
                }
                try expect(!hasSince, "\(feature.rawValue): nothing invented under \(freshness) when no change is authored")
                let paragraphs = blocks.filter {
                    if case .paragraph = $0 { return true }
                    return false
                }
                try expect(paragraphs.count == card.paragraphs.count, "\(feature.rawValue): every paragraph is kept")
                try expect(
                    blocks.suffix(2).map { $0 }
                        == [
                            .list(kind: .solid, heading: BetaWords.solid, lines: card.works),
                            .list(kind: .rough, heading: BetaWords.rough, lines: card.rough),
                        ], "\(feature.rawValue): the lists close the card, solid then rough")
            }
        }
        let plain = BetaFeature.voiceCall.card
        let changed = BetaCard(
            name: plain.name, symbol: plain.symbol, glyph: plain.glyph, title: plain.title,
            lead: plain.lead, paragraphs: plain.paragraphs, works: plain.works, rough: plain.rough,
            changes: [BetaChange(since: SoftwareVersion("1.9")!, line: "It got better.")],
            reportName: plain.reportName)
        let blocks = BetaCardLayout.blocks(for: changed, freshness: .changed)
        try expect(
            blocks.dropFirst(2).first == .since(heading: BetaWords.sinceYouLastLooked, lines: ["It got better."]),
            "a changed card leads with since you last looked, after the lead")
        try expect(
            !BetaCardLayout.blocks(for: changed, freshness: .settled).contains(
                .since(heading: BetaWords.sinceYouLastLooked, lines: ["It got better."])),
            "a settled card does not repeat it")

        guard gtk_init_check() != 0 else { return }
        for feature in BetaFeature.allCases {
            let card = feature.card
            let view = BetaCardView(card: card, freshness: .unseen, onCopy: {}, onClose: {})
            let text = view.text
            let required = [card.title, card.lead, BetaWords.badge, BetaWords.solid, BetaWords.rough, BetaWords.copyReport, BetaWords.gotIt]
                + card.paragraphs + card.works + card.rough
            for word in required {
                try expect(text.contains(word), "\(feature.rawValue): the card shows \"\(word.prefix(32))\"")
            }
            try expect(!text.contains(BetaWords.sinceYouLastLooked), "\(feature.rawValue): no since section on a card with no change")
            try expect(view.copyLabel == BetaWords.copyReport, "\(feature.rawValue): the copy button offers the report")
        }
        let view = BetaCardView(card: changed, freshness: .changed, onCopy: {}, onClose: {})
        try expect(view.text.contains(BetaWords.sinceYouLastLooked) && view.text.contains("It got better."), "the widget draws the since section")
        view.markCopied()
        try expect(view.copyLabel == BetaWords.reportCopied, "copying says the report was copied")
    }

    private static func checkBetaReport(_ expect: (Bool, String) throws -> Void) throws {
        let report = BetaReport.compose(
            feature: .voiceCall, app: "Tailscode 1.80", system: "Arch · gtk 4.22",
            lines: ["Gateway: studio:4102", "Gateway state: ready"])
        try expect(
            report.split(separator: "\n").map(String.init)
                == [
                    BetaReport.heading, "Feature: voiceCall", "App: Tailscode 1.80", "System: Arch · gtk 4.22",
                    "Gateway: studio:4102", "Gateway state: ready",
                ], "the report is the heading, the feature, the app, the system and the surface's lines")
        let system = BetaSystem.line
        try expect(system.contains("gtk ") && !system.isEmpty, "the system line names the toolkit")
    }

    private static func checkBetaSeenStore(_ expect: (Bool, String) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let feature = BetaFeature.delegate
        let key = BetaSeenStore.key(feature)
        let version = SoftwareVersion("1.80")!
        try expect(BetaSeenStore.seen(feature) == nil, "a feature nobody opened has no seen version")
        BetaSeenStore.markSeen(feature, at: version)
        SettingsFile.capture()
        SettingsFile.flush()
        defaults.removeObject(forKey: key)
        try expect(BetaSeenStore.seen(feature) == nil, "the reinstall wiped the defaults")
        SettingsFile.load()
        try expect(BetaSeenStore.seen(feature)?.raw == "1.80", "the seen version survives a reinstall through the settings file")
        try expect(
            BetaSeenStore.freshness(feature, current: version) == .settled,
            "and reads settled for a card with nothing newer to say")
    }

    private static func checkBetaParity(_ expect: (Bool, String) throws -> Void) throws {
        var anchor: String?
        if case .implemented(let named) = ParityManifest.evidence(for: .betaMark) { anchor = named }
        try expect(anchor == "BetaBadge", "the manifest answers the mark with BetaBadge")
        try expect(
            !CapabilityRegistry.definition(for: .betaMark).spec.isEmpty, "the capability has its spec")
    }

    private static func checkBetaBadge(_ expect: (Bool, String) throws -> Void) throws {
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        func host(_ badge: BetaBadge) -> UnsafeMutablePointer<GtkWidget> {
            let window = gtk_window_new()!
            gtk_window_set_default_size(ptr(window), 360, 120)
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
            gtk_box_append(ptr(row), Gtk.label("Feature", selectable: false))
            gtk_box_append(ptr(row), badge.widget)
            gtk_window_set_child(ptr(window), row)
            gtk_window_present(ptr(window))
            return window
        }
        func close(_ window: UnsafeMutablePointer<GtkWidget>, _ badge: BetaBadge) {
            badge.tearDown()
            gtk_window_destroy(ptr(window))
            _ = pump(0.1)
        }

        let feature = BetaFeature.delegate
        let baseline = Int(tailscode_live_ticks())

        let first = BetaBadge(feature: feature) { ["Daemon: studio:4100"] }
        let firstWindow = host(first)
        try expect(pump(3) { first.reading.announced }, "an unseen mark is announced when it is drawn)")
        try expect(first.reading.sheenTurning, "the light runs on its own frame clock")
        let turning = Int(tailscode_live_ticks())
        try expect(turning > baseline, "and the clock is one the process can count")
        try expect(
            pump(BetaSheen.duration + 2) { !first.reading.sheenTurning },
            "the pass ends on its own")
        try expect(Int(tailscode_live_ticks()) < turning, "a settled mark holds no clock of its own")
        close(firstWindow, first)

        let second = BetaBadge(feature: feature) { [] }
        let secondWindow = host(second)
        _ = pump(0.6)
        try expect(!second.reading.sheenTurning, "the second drawing of the same mark in this process is not announced again")
        close(secondWindow, second)

        BetaBadge.forgetAnnouncement(of: feature)
        tailscode_set_animations_enabled(0)
        let still = BetaBadge(feature: feature) { [] }
        let stillWindow = host(still)
        _ = pump(0.6)
        try expect(!still.reading.sheenTurning && !still.reading.announced, "reduced motion draws no light and spends no announcement")
        close(stillWindow, still)
        tailscode_set_animations_enabled(1)

        let opened = BetaBadge(feature: .voiceCall) { ["Gateway: studio:4102"] }
        let openedWindow = host(opened)
        _ = pump(0.3)
        try expect(!opened.reading.cardOpen, "the card is shut until asked for")
        opened.open()
        try expect(opened.reading.cardOpen, "opening shows the card")
        try expect(
            BetaSeenStore.seen(.voiceCall)?.raw == BetaBadge.appVersion.raw,
            "opening the card marks it seen at this app's version")
        try expect(!opened.reading.sheenTurning, "an opened mark runs no light")
        try expect(
            opened.report().contains("Gateway: studio:4102") && opened.report().contains("Feature: voiceCall"),
            "the badge's report carries its surface's lines")
        try expect(opened.cardText?.contains(BetaFeature.voiceCall.card.title) == true, "the open card is the feature's own")
        opened.close()
        try expect(!opened.reading.cardOpen, "Got it shuts the card")
        close(openedWindow, opened)
        try expect(Int(tailscode_live_ticks()) <= baseline, "every clock a mark took is back")
    }
}
