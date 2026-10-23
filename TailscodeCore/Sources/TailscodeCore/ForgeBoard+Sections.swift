import Foundation

extension ForgeBoard {
    func rendererSection() -> ForgeSection {
        let row = ForgeRow(
            sectionID: Self.rendererID, kind: .field(.endpoint), title: value(of: .endpoint),
            detail: rendererLine, badge: endpoint == nil ? nil : reachBadge)
        return ForgeSection(
            id: Self.rendererID, title: ForgeField.endpoint.label, detail: rendererCall,
            phase: reach, rows: [row], hidden: 0)
    }

    /// What the renderer section offers before there is a renderer. A section that says nothing
    /// where the whole feature is blocked is a dead end; this is the one line that names both ways
    /// out, and the row under it opens the surface that does either.
    private var rendererCall: String {
        endpoint == nil ? Localized.text("Find it on your tailnet, or type its address") : ""
    }

    private var rendererLine: String {
        switch reach {
        case .failed(let reason): return reason
        case .checking:
            if let readiness, readiness.isStarting, let check = readiness.check("media.comfy") {
                return MediaReading.comfyDetail(check, endpoint: readiness.endpoint)
            }
            return Localized.text("Checking…")
        case .ready:
            if let blocker { return blocker.sentence }
            return Localized.text("Answering on %@", "\(endpoint?.port ?? ForgeEndpoint.defaultPort)")
        case .idle:
            return endpoint == nil
                ? Localized.text("Point this at the machine with the card")
                : Localized.text("Not checked yet")
        }
    }

    private var reachBadge: String? {
        switch reach {
        case .ready: return blocker == nil ? Localized.text("up") : Localized.text("not ready")
        case .failed: return Localized.text("down")
        case .checking, .idle: return nil
        }
    }

    func renderSection() -> ForgeSection {
        let row = ForgeRow(
            sectionID: Self.renderID, kind: .job, title: job.title, detail: job.subtitle,
            badge: job.badge, note: job.detail, fraction: job.fraction, isPrimary: true)
        return ForgeSection(
            id: Self.renderID, title: Localized.text("Render"), detail: renderCall, phase: renderPhase,
            rows: [row], hidden: 0)
    }

    /// What the stage shows while nothing plays, in one reading: the sketch when the machine has
    /// sent one, else the phase's own glyph.
    public var sketch: ImageGenPreviewFrame? { job.sketch }

    /// What the button under the render says it would do, which is the same question `begin()`
    /// answers — said in words here so a client never has to guess a caption from a phase.
    public var renderCall: String {
        if job.isBusy { return Localized.text("Stop") }
        if job.asset != nil { return Localized.text("Play") }
        if endpoint == nil { return ForgeSetup.title }
        if blocker != nil { return Localized.text("See what is missing") }
        return Localized.text("Render")
    }

    private var renderPhase: ForgePhase {
        switch job.phase {
        case .drafting: return .idle
        case .submitting, .queued, .running: return .checking
        case .done: return .ready
        case .failed(let reason): return .failed(reason)
        case .cancelled: return .idle
        }
    }

    /// The settings, disabled while a render is in flight: the graph on the other machine was built
    /// from the recipe as it stood when it was posted, and a row that looks editable but changes
    /// nothing about what is on screen is worse than a row that says it is out of reach.
    func settingsSection() -> ForgeSection {
        let fields: [ForgeField] = [
            .prompt, .negative, .sound, .frame, .size, .seconds, .fps, .seed,
        ]
        let rows = fields.map { field in
            ForgeRow(
                sectionID: Self.settingsID, kind: .field(field), title: field.label,
                detail: value(of: field), note: hint(for: field), enabled: !job.isBusy)
        }
        return ForgeSection(
            id: Self.settingsID, title: Localized.text("Settings"), detail: recipe.summary,
            phase: .ready, rows: rows, hidden: 0)
    }

    private func hint(for field: ForgeField) -> String? {
        switch field {
        case .seconds: return Localized.text("%@ frames", "\(recipe.length)")
        case .seed: return Localized.text("The same seed and prompt make the same clip")
        case .sound: return ForgeWords.soundHint
        case .frame: return recipe.frame?.detail ?? ForgeWords.frameHint
        case .negative: return ForgeWords.negativeIgnoredHint
        case .endpoint, .prompt, .size, .fps: return nil
        }
    }

    func historySection() -> ForgeSection? {
        guard kept != .idle || !history.isEmpty else { return nil }
        let built = history.map { entry in
            ForgeRow(
                sectionID: Self.historyID, kind: .clip(entry), title: entry.title,
                detail: entry.detail, badge: entry.badge)
        }
        return section(
            id: Self.historyID, title: Localized.text("Recent"),
            detail: Localized.text("%@ kept", "\(history.count)"), phase: kept, rows: built,
            empty: Localized.text("Nothing rendered yet"))
    }

    /// One section, compacted: the first few rows, then one row standing for the rest. A section
    /// that is waiting or that failed says so as its own row rather than as a missing section.
    private func section(
        id: String, title: String, detail: String, phase: ForgePhase, rows: [ForgeRow],
        empty: String, limit: Int = ForgeBoard.compactLimit
    ) -> ForgeSection {
        if rows.isEmpty {
            let line: String?
            switch phase {
            case .checking: line = Localized.text("Checking…")
            case .failed(let reason): line = reason
            case .ready: line = empty.isEmpty ? nil : empty
            case .idle: line = nil
            }
            guard let line else {
                return ForgeSection(
                    id: id, title: title, detail: detail, phase: phase, rows: [], hidden: 0)
            }
            return ForgeSection(
                id: id, title: title, detail: detail, phase: phase,
                rows: [ForgeRow(sectionID: id, kind: .note, title: line, detail: "")], hidden: 0)
        }
        let showsAll = expanded.contains(id) || rows.count <= limit
        let shown = showsAll ? rows : Array(rows.prefix(limit))
        let hidden = rows.count - shown.count
        var built = shown
        if hidden > 0 {
            built.append(
                ForgeRow(
                    sectionID: id, kind: .expander(id), title: Localized.text("%@ more", "\(hidden)"),
                    detail: Localized.text("tab shows them")))
        } else if showsAll, rows.count > limit {
            built.append(
                ForgeRow(
                    sectionID: id, kind: .expander(id), title: Localized.text("Fewer"),
                    detail: Localized.text("tab hides them again")))
        }
        if case .failed(let reason) = phase {
            built.append(ForgeRow(sectionID: id, kind: .note, title: reason, detail: ""))
        }
        return ForgeSection(
            id: id, title: title, detail: detail, phase: phase, rows: built, hidden: hidden)
    }
}
