import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// A streamed token changes exactly one row, and rebuilding its widget for every arrival is
    /// what makes a live answer flicker: the label is torn down and remade dozens of times a
    /// second, which restarts its entrance, drops any selection inside it, and asks the whole
    /// column to lay out again. When the only difference is more words in a row that can take them
    /// where it stands — the answer the painter is holding, or a thought counting itself up — the
    /// change is written into the widget and the bookkeeping moves with it. A link rail docked
    /// under the paragraph is the paragraph's own and does not make it any less the last row.
    func updatedLastRowInPlace(_ rows: [TranscriptRow]) -> Bool {
        guard !placeholderShown, fillComplete,
            renderedRows.count == rows.count,
            let last = rows.lastIndex(where: { !$0.isLinkRail }), last > 0,
            renderedRows[last].key == rows[last].key, renderedRows[last] != rows[last],
            last < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[last]),
            renderedRows.prefix(last).elementsEqual(rows.prefix(last)),
            renderedRows.suffix(from: last + 1).elementsEqual(rows.suffix(from: last + 1))
        else { return false }
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        switch (renderedRows[last].kind, rows[last].kind) {
        case (.agentProse, .agentProse), (.codeBlock, .codeBlock):
            guard rows[last].key == cascade.key else { return restateProseWhole(rows[last], on: widget, at: last) }
            let previous = renderedRows[last]
            renderedRows[last] = rows[last]
            guard paintCascade() else {
                renderedRows[last] = previous
                return false
            }
            return true
        case (.reasoning, .reasoning(let text)):
            guard TranscriptRow.restateReasoning(
                widget, text: text, key: rows[last].key, context: context)
            else { return false }
        case (.pendingSend, .pendingSend(let send, let plan)):
            guard TranscriptRow.restatePending(on: widget, send: send, plan: plan) else {
                return false
            }
            renderedRows[last] = rows[last]
            return true
        case (.brain, .brain(let brain)):
            guard let view = BrainView.current(of: widget) else { return false }
            view.restate(brain)
            renderedRows[last] = rows[last]
            return true
        default:
            return false
        }
        renderedRows[last] = rows[last]
        if followsBottom { scrollToBottom() }
        return true
    }

    /// A pane that does not reveal still takes an answer's growth in place: the words go into the
    /// label the row already has, whole, so a peer's live answer costs one markup set per applied
    /// state rather than a new widget, a new entrance and a relayout of the column.
    func restateProseWhole(
        _ row: TranscriptRow, on widget: UnsafeMutablePointer<GtkWidget>, at index: Int
    ) -> Bool {
        guard cascade.key == nil, case .agentProse = row.kind,
            let label = Self.streamedLabel(in: widget, kind: row.kind),
            let markup = Self.settleMarkup(for: row), cascade.settle(label, markup: markup)
        else { return false }
        renderedRows[index] = row
        if canvasPromptKey != nil {
            settleFreshCanvas()
        } else if followsBottom {
            pinToBottom()
        }
        return true
    }

    /// A row that stopped being written ends up whole, whatever the wave was doing when it let go.
    ///
    /// Settling is normally the release path's job, but that path can only settle the row the
    /// painter still holds: a key that changed as the message completed, a widget rebuilt between
    /// frames, a turn that ended in the same update its last words arrived in, or a painter that
    /// declined the row all leave it holding nothing. So the pane remembers the row the wave last
    /// had its hands on and hands it back the first state where the wave is no longer on it —
    /// which is any state at all, not only one that says the turn is over. A stream that simply
    /// stops sending never says that, and the reveal is a prefix painted into the row's own label:
    /// the rows are equal by then, so the diff sees nothing to do and nothing else would ever put
    /// the rest of the sentence back.
    ///
    /// The row is let go of only once it has actually been handed back. A settle can find nothing
    /// to write into — the row is mid-chunk, its widget was rebuilt between frames, the pane is
    /// showing a placeholder — and forgetting the key on the way in turns one missed repair into a
    /// permanent one: nothing else in the pane knows that widget is holding a prefix. Keeping it
    /// costs a string and retries on the next state, which is where the widget usually is by then.
    func settleStreamedTail(in rows: [TranscriptRow]) {
        guard let key = lastStreamedKey, key != cascade.key else { return }
        if settleCascade(on: key, in: rows) || !lastFullRows.contains(where: { $0.key == key }) {
            lastStreamedKey = nil
            return
        }
        scheduleTailRepair(on: key)
    }

    /// A settle that could not be made, tried again on a clock of its own.
    ///
    /// Every other road back to a whole row runs through a state arriving: the diff, the release
    /// path, the tail settle. A turn that has just ended sends no more states, and the wave let go
    /// of its frame clock and its watchdog in the same breath — so a settle that failed at exactly
    /// that moment is the last thing anybody was ever going to try, and the row keeps the prefix
    /// for as long as the chat is open. This is the clock nothing else can take down.
    ///
    /// It gives up on being polite before it gives up on the reader: three refusals and the row's
    /// bookkeeping is thrown away so the ordinary diff has to build it again from the words the
    /// pane actually holds, which is slower, loses a selection inside that one row, and is still
    /// enormously better than a paragraph that stops mid-sentence.
    func scheduleTailRepair(on key: String) {
        repairKey = key
        guard !repairingTail else { return }
        repairingTail = true
        tailRepairs = 0
        repairStreamedTail()
    }

    func repairStreamedTail() {
        Gtk.after(320) { [weak self] in
            guard let self, self.repairingTail else { return }
            guard let key = self.repairKey, key != self.cascade.key else {
                self.repairingTail = false
                self.repairKey = nil
                return
            }
            if self.settleCascade(on: key, in: self.lastFullRows) {
                if self.lastStreamedKey == key { self.lastStreamedKey = nil }
                self.repairingTail = false
                self.repairKey = nil
                return
            }
            self.tailRepairs += 1
            guard self.tailRepairs >= 3 else {
                self.repairStreamedTail()
                return
            }
            self.repairingTail = false
            self.repairKey = nil
            if self.lastStreamedKey == key { self.lastStreamedKey = nil }
            self.rebuildStreamedTail(from: key)
        }
    }

    /// Forgets everything the pane believes about the row the wave was painting and the rows after
    /// it, so the next fill cannot compare them equal and skip them. The words are the pane's own,
    /// so nothing is refetched — only redrawn.
    func rebuildStreamedTail(from key: String) {
        guard !placeholderShown, let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowWidgets.count
        else { return }
        while renderedRows.count > index { removeRowWidget(at: renderedRows.count - 1) }
        let limit = rowLimit
        let rows = lastFullRows
        applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
    }

    /// The reveal stopped moving while it still owed the reader text — the frame clock died under
    /// it, or the words stopped arriving. Either way the hand is not coming back, so the row is
    /// given up and shown whole rather than left mid-sentence.
    ///
    /// Given up means for good, for as long as that row is the one being written: taking it back
    /// on the next arrival would start its reveal again from nothing, and an answer that snapped
    /// to whole and then rewound would be a worse lie than the stall.
    func giveUpCascade() {
        if reopenGatedCascade() { return }
        let key = cascade.key ?? lastStreamedKey
        cascade.release()
        abandoned = key
        lastStreamedKey = key
        guard let key else { return }
        if settleCascade(on: key, in: lastFullRows) {
            lastStreamedKey = nil
        } else {
            scheduleTailRepair(on: key)
        }
    }

    /// The wave letting go of a row is not the same as the row being rebuilt. A turn that simply
    /// ends leaves the rows identical, so the diff has nothing to do and the last glyphs would keep
    /// the heat of a stream that stopped — the row has to be handed back whole by hand.
    ///
    /// Whole means the row's own words, which is what the pane last received and never what the
    /// pacer handed the widget: the paced copy is cut at the last position where no markdown token
    /// is half-open, and settling from it would bake that cut into the finished answer. Returns
    /// whether the row is now whole, so a repair that could not be made is not mistaken for one
    /// that was.
    @discardableResult
    func settleCascade(on key: String, in rows: [TranscriptRow]) -> Bool {
        guard let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let label = Self.streamedLabel(in: ptr(raw), kind: renderedRows[index].kind)
        else { return false }
        let row =
            lastFullRows.last(where: { $0.key == key })
            ?? rows.last(where: { $0.key == key })
            ?? renderedRows[index]
        guard let markup = Self.settleMarkup(for: row) else { return false }
        return cascade.settle(label, markup: markup)
    }

    /// What the shim should parse for this row while the wave is on it. Prose already carries its
    /// markup; a code block is its own body, escaped, so the one reveal path serves both.
    ///
    /// The painter parses markup with Pango's own parser, and Pango has no anchor of its own —
    /// GtkLabel resolves `<a href>` before Pango ever sees it. So a link is dressed as the span
    /// the label would have made of it: same ink, same underline, no semantics. A frame needs none.
    /// Prose that carries no link is handed back exactly as it came, because the dressing below
    /// rewrites a string the size of the whole answer and most answers have nothing in them to
    /// rewrite. Returning the markup itself costs nothing at all; building an identical copy of it
    /// costs the answer, every time somebody asks.
    static func cascadeMarkup(for row: TranscriptRow) -> String? {
        switch row.kind {
        case .agentProse(_, let markup):
            guard markup.contains("<a href=\"") else { return markup }
            let accent = MatrixTheme.palette.accent
            var text = markup.replacingOccurrences(of: "</a>", with: "</span>")
            while let open = text.range(of: "<a href=\""),
                let close = text[open.upperBound...].range(of: "\">")
            {
                text.replaceSubrange(
                    open.lowerBound..<close.upperBound,
                    with: "<span foreground=\"\(accent)\" underline=\"single\">")
            }
            return text
        case .codeBlock(_, let body):
            return PangoMarkdown.escape(body)
        default:
            return nil
        }
    }

    /// What a row is handed back whole with. Settling writes through `gtk_label_set_markup`, which
    /// is GtkLabel's own road — the one that turns `<a href>` into a link a click can follow. The
    /// painter's dressed markup must never reach it: a span carries the link's ink but not its
    /// address, so a row settled in what the frames were painted with would spend the rest of the
    /// chat looking touchable and doing nothing. The undressed markup is the row's own, exactly
    /// what a rebuild would have set; a code block still rides escaped, as it always did.
    static func settleMarkup(for row: TranscriptRow) -> String? {
        switch row.kind {
        case .agentProse(_, let markup): return markup
        case .codeBlock(_, let body): return PangoMarkdown.escape(body)
        default: return nil
        }
    }

    /// Where a live row keeps the words: prose is the label, a code block keeps its body under the
    /// header and behind a scroller once it is tall enough to need one.
    static func streamedLabel(
        in widget: UnsafeMutablePointer<GtkWidget>, kind: TranscriptRow.Kind
    ) -> UnsafeMutablePointer<GtkWidget>? {
        func isA(_ candidate: UnsafeMutablePointer<GtkWidget>, _ type: GType) -> Bool {
            let instance = UnsafeMutableRawPointer(candidate).assumingMemoryBound(
                to: GTypeInstance.self)
            return g_type_check_instance_is_a(instance, type) != 0
        }
        switch kind {
        case .agentProse:
            return isA(widget, gtk_label_get_type()) ? widget : nil
        case .codeBlock:
            guard let last = gtk_widget_get_last_child(widget) else { return nil }
            if isA(last, gtk_label_get_type()) { return last }
            guard isA(last, gtk_scrolled_window_get_type()),
                let child = gtk_scrolled_window_get_child(op(last)),
                isA(child, gtk_label_get_type())
            else { return nil }
            return child
        default:
            return nil
        }
    }

    /// A notice is transient — the last thing the app did on this pane's behalf — and it lives at
    /// the far end of the band so it never pushes a live fact off it.
    func setNotice(_ text: String) {
        notice = text
        updateStatus()
    }

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started lazily on the first turn tick after a chat opens.
    func startAgentStreamIfAvailable() {
        guard agentStreamSessionID != sessionID else { return }
        guard let backend, let entry else { return }
        agentStreamSessionID = entry.session.id
        let sessionID = entry.session.id
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else {
                Gtk.onMain { [weak self] in self?.agentStreamSessionID = nil }
                return
            }
            for await agents in changes {
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.applyAgentFacts(agents)
                }
            }
        }
    }

    func applyAgentFacts(_ agents: [SubagentSummary]) {
        self.agents = agents
        var facts: [String: SubagentSummary] = [:]
        for agent in agents {
            if let toolUseID = agent.toolUseID { facts[toolUseID] = agent }
        }
        let changed = facts.keys.filter { context.agentFacts[$0] != facts[$0] }
        let vanished = context.agentFacts.keys.filter { facts[$0] == nil }
        context.agentFacts = facts
        let stale = Set(changed + vanished)
        if !stale.isEmpty {
            replaceRows {
                switch $0.kind {
                case .subagent(let call): return stale.contains(call.id)
                case .subagentGroup(let members):
                    return members.contains { stale.contains($0.call.id) }
                default: return false
                }
            }
        }
        refreshWorkflowRuns()
        updateStatus()
    }

    /// Subagents and cost are polled rather than streamed: the bridge reports both on request
    /// only, and a fan-out is worth watching while it runs. Git porcelain is the expensive half
    /// and moves on its own slower clock — a live workflow does not need a repo re-read every few
    /// seconds to keep its elapsed reading honest.
    func refreshTurnFacts(includeGit: Bool = true) {
        guard let backend, let entry else { return }
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        let wantGit = includeGit
        track(Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            let report = (try? await backend.sessionSpend(sessionID)) ?? nil
            let repository =
                wantGit ? await Self.readGit(backend: backend, session: entry.session) : nil
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.usage = usage
                self.lastNetworkFactsAt = Date()
                if wantGit {
                    self.git = repository.map { GitState(snapshot: $0) }
                    self.lastGitFactsAt = Date()
                }
                self.spendReading.note(report: report, for: sessionID)
                self.spendReading.note(
                    messages: self.lastState?.messages ?? [], for: sessionID)
                if let agents {
                    self.applyAgentFacts(agents)
                } else {
                    self.updateStatus()
                }
            }
        })
    }

    /// The repository the conversation is working in, when the server can read one. A backend
    /// without the routes, or a directory outside version control, answers nil and the band simply
    /// has one fewer fact — never an error about a repository nobody asked for.
    static func readGit(backend: any CodingAgentBackend, session: AgentSession) async
        -> GitSnapshot?
    {
        await readGit(backend: backend, directory: session.directory, sessionID: session.id)
    }

    static func readGit(
        backend: any CodingAgentBackend, directory: String?, sessionID: String
    ) async -> GitSnapshot? {
        guard let observer = backend as? any GitObservingBackend else { return nil }
        let snapshot = try? await observer.gitSnapshot(
            directory: directory, sessionID: sessionID)
        return (snapshot?.repo == true) ? snapshot : nil
    }

    /// A once-a-second nudge while anything on screen still needs a clock: elapsed, pending
    /// captions, workflow spinners. Network facts and git ride slower cadences so a multi-pane
    /// window does not re-read porcelain six times a minute per chat.
    func updateTicker(running: Bool, quietly: Bool = false) {
        let running = (running || needsTicker) && !isParked && !quietly
        if quietly {
            tickerTask?.cancel()
            tickerTask = nil
            return
        }
        if running, tickerTask == nil {
            lastNetworkFactsAt = nil
            lastGitFactsAt = nil
            refreshTurnFacts(includeGit: true)
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    Gtk.onMain { [weak self] in
                        guard let self, !self.isShutDown, self.tickerTask != nil else { return }
                        self.updateStatus()
                        self.updateCompactingElapsed()
                        self.updatePendingCaptions()
                        self.advanceLiveClock()
                        self.tickTurnFacts()
                    }
                }
            }
        } else if !running {
            if tickerTask != nil {
                tickerTask?.cancel()
                tickerTask = nil
                refreshTurnFacts(includeGit: true)
            }
        }
    }

    static let networkFactsInterval: TimeInterval = 15

    static let gitFactsInterval: TimeInterval = 60

    func tickTurnFacts() {
        guard needsTicker, BackgroundGate.shared.isVisible else { return }
        let now = Date()
        let networkDue =
            lastNetworkFactsAt.map { now.timeIntervalSince($0) >= Self.networkFactsInterval }
            ?? true
        let gitDue =
            lastGitFactsAt.map { now.timeIntervalSince($0) >= Self.gitFactsInterval } ?? true
        guard networkDue || gitDue else { return }
        refreshTurnFacts(includeGit: gitDue)
    }

    /// Ages every wait countdown that is still on screen; a plain send's caption is woken by
    /// `scheduleCaptionWake` instead.
    func updatePendingCaptions() {
        guard !resume.isEmpty else { return }
        let now = Date()
        for index in renderedRows.indices {
            guard case .pendingSend = renderedRows[index].kind, index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            TranscriptRow.agePendingCaption(on: ptr(raw), now: now)
        }
    }

    func refreshPills() {
        let destination = [
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) },
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        let face = ModelDial.face(
            modelWord: modelPillText(), effort: resolvedEffort(), options: effortOptions())
        let tint = modelTintClass() ?? ""
        let signature =
            "\(destination)|\(face.modelWord)|\(face.effortWord ?? "")|\(face.heat)|\(face.isPower)|\(tint)|\(abilities.attachments)"
        guard signature != lastPillsSignature else {
            dropUnsendableAttachments()
            return
        }
        lastPillsSignature = signature
        gtk_label_set_text(op(destinationLabel), destination)
        Gtk.fitWrap(destinationLabel, to: destination, ceiling: 60)
        renderDial(face)
        attachAble = abilities.attachments
        if !attachAble, let attachButton { gtk_widget_set_visible(attachButton, 0) }
        queueLaneFit()
        dropUnsendableAttachments()
    }

    /// A model switch is the one way something already picked becomes unsendable. It is dropped
    /// out loud rather than left to fail on the other machine, and never silently: a picture that
    /// vanishes from a composer with no word is the app losing work.
    func dropUnsendableAttachments() {
        let able = abilities
        let refused = attachments.filter { !able.accepts(mime: $0.mime) }
        guard !refused.isEmpty else { return }
        attachments.removeAll { attachment in refused.contains { $0.id == attachment.id } }
        renderAttachments()
        setNotice(ModelAbilities.dropped(refused.count))
    }
}
