import CodingAgentKit
import Foundation

/// One card that explains a tab or a door: what it is, the state it is in, and exactly what is
/// behind it. The words are Core's so the three clients cannot disagree; a client draws headings,
/// lines and a footnote, and adds nothing.
public struct ChooserBriefing: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        public let label: String
        public let value: String
        /// An SF Symbol name where the platform has symbols; the text desks draw `glyph`.
        public let symbol: String?
        public let glyph: String?

        public init(label: String, value: String, symbol: String? = nil, glyph: String? = nil) {
            self.label = label
            self.value = value
            self.symbol = symbol
            self.glyph = glyph
        }
    }

    public struct Section: Sendable, Hashable {
        public let heading: String
        public let lines: [Line]
        public let footnote: String?

        public init(heading: String, lines: [Line], footnote: String? = nil) {
            self.heading = heading
            self.lines = lines
            self.footnote = footnote
        }
    }

    public let title: String
    public let subtitle: String
    public let tone: ModelMachineState.Tone?
    public let lead: String
    public let sections: [Section]

    public init(
        title: String, subtitle: String, tone: ModelMachineState.Tone?, lead: String,
        sections: [Section]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.lead = lead
        self.sections = sections
    }
}

extension ModelChooser {
    /// The card behind a machine's tab.
    public func briefing(machine profileID: String) -> ChooserBriefing? {
        guard let machine = machines.first(where: { $0.profileID == profileID }),
            let source = sources.first(where: { $0.profileID == profileID })
        else { return nil }
        let mine = candidates.filter { $0.profileID == profileID }
        var sections: [ChooserBriefing.Section] = []

        var state = [
            ChooserBriefing.Line(
                label: Localized.text("State"), value: machine.state.word,
                symbol: "circle.fill", glyph: "●")
        ]
        if machine.isCurrent {
            state.append(
                ChooserBriefing.Line(
                    label: Localized.text("This chat"),
                    value: Localized.text("A pick here changes this conversation in place"),
                    symbol: "bubble.left", glyph: "▸"))
        } else {
            state.append(
                ChooserBriefing.Line(
                    label: Localized.text("A pick here"),
                    value: Localized.text("Starts a new chat on %@", machine.title),
                    symbol: "plus.bubble", glyph: "+"))
        }
        sections.append(
            ChooserBriefing.Section(
                heading: Localized.text("Now"), lines: state,
                footnote: machine.state.explanation))

        var catalog = [
            ChooserBriefing.Line(
                label: Localized.text("Models"), value: Self.modelCount(mine.count),
                symbol: "cpu", glyph: "#")
        ]
        let families = Set(mine.filter { !$0.isLocal }.map(\.family.key)).count
        if families > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Families"), value: "\(families)",
                    symbol: "square.stack.3d.up", glyph: "≡"))
        }
        if machine.localCount > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("On its own hardware"),
                    value: Self.modelCount(machine.localCount), symbol: "desktopcomputer",
                    glyph: "⌂"))
        }
        let vision = mine.filter { $0.capabilities?.imageInput == true }.count
        if vision > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("See pictures"), value: Self.modelCount(vision),
                    symbol: "eye", glyph: "◉"))
        }
        let pdf = mine.filter { $0.capabilities?.pdfInput == true }.count
        if pdf > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Read PDFs"), value: Self.modelCount(pdf),
                    symbol: "doc.text", glyph: "▤"))
        }
        let levelled = mine.filter { !$0.variants.isEmpty }.count
        if levelled > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Take an effort level"), value: Self.modelCount(levelled),
                    symbol: "dial.medium", glyph: "◔"))
        }
        let walled = mine.filter { walls[$0.selection.rawValue] != nil }.count
        if walled > 0 {
            catalog.append(
                ChooserBriefing.Line(
                    label: Localized.text("Used up"), value: Self.modelCount(walled),
                    symbol: "exclamationmark.octagon", glyph: "!"))
        }
        sections.append(
            ChooserBriefing.Section(
                heading: Localized.text("Catalog"), lines: catalog,
                footnote: Self.catalogFootnote(source)))

        let doorsHere = doors(on: profileID)
        if !doorsHere.isEmpty {
            sections.append(
                ChooserBriefing.Section(
                    heading: Localized.text("Doors"),
                    lines: doorsHere.map { door in
                        ChooserBriefing.Line(
                            label: door.title,
                            value: Self.modelCount(door.count) + " · " + door.kind.title,
                            symbol: door.kind.symbol, glyph: door.kind.glyph)
                    },
                    footnote: Localized.text(
                        "A door is the account a request goes through — a plan, a key, a gateway, or the machine itself. The same model behind two doors is one row with a chevron; a pick made under a door goes through that door.")))
        }
        return ChooserBriefing(
            title: machine.title, subtitle: Self.backendLine(source.backend),
            tone: machine.state.tone, lead: Self.backendStory(source.backend), sections: sections)
    }

    /// The card behind a door's chip.
    public func briefing(door providerID: String) -> ChooserBriefing? {
        guard let door = doors.first(where: { $0.providerID == providerID }),
            let machine = shownMachine
        else { return nil }
        let through = wholeMachine.compactMap { candidate in
            candidate.offers.first { $0.providerID == providerID }.map { (candidate, $0) }
        }
        var lines = [
            ChooserBriefing.Line(
                label: Localized.text("Kind"), value: door.kind.title, symbol: door.kind.symbol,
                glyph: door.kind.glyph),
            ChooserBriefing.Line(
                label: Localized.text("Models"), value: Self.modelCount(door.count), symbol: "cpu",
                glyph: "#"),
        ]
        let alsoElsewhere = through.filter { $0.0.offers.count > 1 }.count
        if alsoElsewhere > 0 {
            lines.append(
                ChooserBriefing.Line(
                    label: Localized.text("Also behind another door"),
                    value: Self.modelCount(alsoElsewhere), symbol: "arrow.triangle.swap",
                    glyph: "⇄"))
        }
        let walled = through.filter { walls[$0.1.selection.rawValue] != nil }.count
        if walled > 0 {
            lines.append(
                ChooserBriefing.Line(
                    label: Localized.text("Used up"), value: Self.modelCount(walled),
                    symbol: "exclamationmark.octagon", glyph: "!"))
        }
        var sections = [
            ChooserBriefing.Section(
                heading: Localized.text("This door"), lines: lines,
                footnote: door.kind.explanation)
        ]
        var byFamily: [ModelFamily: Int] = [:]
        for (candidate, _) in through { byFamily[candidate.family, default: 0] += 1 }
        let families = byFamily.keys.sorted().prefix(8)
        if !families.isEmpty {
            sections.append(
                ChooserBriefing.Section(
                    heading: Localized.text("Behind it"),
                    lines: families.map { family in
                        ChooserBriefing.Line(
                            label: family.title, value: Self.modelCount(byFamily[family] ?? 0))
                    },
                    footnote: byFamily.count > families.count
                        ? Localized.text("and %@ more families", "\(byFamily.count - families.count)")
                        : nil))
        }
        return ChooserBriefing(
            title: door.title,
            subtitle: Localized.text("on %@", machine.title), tone: nil,
            lead: Localized.text(
                "Narrowing to this door lists only what %@ runs through it, and a pick goes through it.",
                machine.title), sections: sections)
    }

    /// The doors of any machine, not only the shown one, for a briefing opened on another tab.
    private func doors(on profileID: String) -> [ModelDoor] {
        var counts: [String: Int] = [:]
        var local: Set<String> = []
        for candidate in candidates where candidate.profileID == profileID {
            for offer in candidate.offers {
                counts[offer.providerID, default: 0] += 1
                if offer.isLocal { local.insert(offer.providerID) }
            }
        }
        return counts.map { id, count in
            ModelDoor(
                providerID: id, title: ProviderIdentity.displayName(id), count: count,
                isLocal: local.contains(id))
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.title < rhs.title : lhs.count > rhs.count
        }
    }

    static func backendLine(_ backend: AgentType) -> String {
        switch backend {
        case .openCode: return Localized.text("opencode server")
        case .claudeCode: return Localized.text("Claude Code, through claude-bridge")
        case .omp: return Localized.text("Oh My Pi server")
        }
    }

    /// Where this kind of server gets its catalog, said once so a missing model is a fact about
    /// configuration rather than a mystery about the app.
    static func backendStory(_ backend: AgentType) -> String {
        switch backend {
        case .openCode:
            return Localized.text(
                "opencode lists every provider configured on that machine — its opencode.json, the keys in its environment, and any local runtime it found — and every model each of them offers. A model missing here is missing from that machine's configuration, not from Tailscode.")
        case .claudeCode:
            return Localized.text(
                "Claude Code answers to one account, so the catalog is a shortlist of Anthropic's models rather than every legal answer: the CLI runs whatever --model it is handed, and a model id typed into the search is offered as-is.")
        case .omp:
            return Localized.text(
                "Oh My Pi lists the providers its own configuration reaches. A model missing here is missing from that machine's setup.")
        }
    }

    static func catalogFootnote(_ source: ModelSource) -> String? {
        guard source.acceptsAnyModelID else { return nil }
        return Localized.text(
            "This server also runs model ids it never listed — type one into the search and it is offered as-is.")
    }
}
