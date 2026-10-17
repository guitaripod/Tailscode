import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Everything the brain promises that a screenshot cannot say: where each turn's brain goes among
    /// the rows and what it takes with it, that the Lines style and a machine without the layers
    /// keep today's rows exactly, that a streamed token reads one turn and not the conversation, and
    /// — on a real widget in a real window — the stage's layout, hit test, hover card, pin, replay,
    /// scrub and dive, that a settled head owns no clock, that reduced motion holds every state
    /// still, that a hidden pane owns no picture, and that closing the last head frees the layers.
    static func checkBrain() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("brain: \(label)") }
            checks += 1
        }

        try checkBrainRows(expect)
        try checkBrainFallbacks(expect)
        try checkBrainWidget(expect)
        try checkBrainPoster(expect)
        try checkBrainAnchor(expect)
        try checkBrainSurfaces(expect)
        return checks
    }

    private static func brainMessages() -> [ChatMessage] { NeuralDemo.conversation() }

    static func brainState(_ messages: [ChatMessage], running: Bool = false) -> ConversationState {
        ConversationState(
            messages: messages, status: running ? .running : .idle, connection: .live,
            hasLoadedTranscript: true)
    }

    static func brainBuilder(
        style: ActivityStyle, rowsShown: Set<String> = []
    ) -> TranscriptRowBuilder {
        let builder = TranscriptRowBuilder()
        builder.setBrains(
            BrainBuildSettings(
                style: style, choices: [:], rowsShown: rowsShown, look: MatrixTheme.palette.name))
        return builder
    }

    private static func isBrain(_ row: TranscriptRow) -> Bool {
        if case .brain = row.kind { return true }
        return false
    }

    private static func isStepRow(_ row: TranscriptRow) -> Bool {
        switch row.kind {
        case .tool, .reasoning, .run: return true
        default: return false
        }
    }

    private static func checkBrainRows(_ expect: (Bool, String) throws -> Void) throws {
        let messages = brainMessages()
        let state = brainState(messages)
        let rows = brainBuilder(style: .brain).rows(state: state)
        let brains = rows.compactMap { row -> BrainRow? in
            if case .brain(let brain) = row.kind { return brain }
            return nil
        }
        try expect(brains.count == 2, "one brain per turn, two turns, two brains (got \(brains.count))")
        try expect(
            rows.filter(isBrain).map(\.key) == ["brain:a-m1", "brain:b-m1"],
            "a brain row is named for its turn, in the order of the turns")
        try expect(
            brains.map(\.open) == [false, true],
            "the latest turn is open by default and the earlier one is closed")
        try expect(
            !rows.contains(where: isStepRow),
            "the parts a brain consumes build no rows of their own")
        let cards = rows.filter {
            if case .subagent = $0.kind { return true }
            return false
        }
        try expect(cards.count == 2, "a Task keeps its card beside the brain (\(cards.count) cards, want 2)")
        let prose = rows.compactMap { row -> String? in
            if case .agentProse(let text, _) = row.kind { return text }
            return nil
        }
        try expect(
            !prose.contains { $0.contains("Building it from the existing film rig") || $0.contains("Song mapped") },
            "a note the agent wrote on the way is a node, not a paragraph")
        try expect(
            prose.contains { $0.contains("Fixed. Both switches answer the new cases.") }
                && prose.contains { $0.contains("Done. The demo is at") },
            "the answer after the last tool stays a paragraph under its brain")
        let firstBrain = rows.firstIndex(where: isBrain) ?? -1
        let firstCard = rows.firstIndex(where: {
            if case .subagent = $0.kind { return true }
            return false
        }) ?? -1
        try expect(
            firstBrain >= 0 && firstBrain < firstCard,
            "the brain stands where the turn's first step was, above the cards")
        try expect(
            rows.map(\.key).count == Set(rows.map(\.key)).count, "every row key is unique")

        let lines = brainBuilder(style: .lines).rows(state: state)
        let today = TranscriptRowBuilder().rows(state: state)
        try expect(!lines.contains(where: isBrain), "the Lines style draws no brain")
        try expect(lines == today, "the Lines style gives today's rows exactly")
        try expect(lines.contains(where: isStepRow), "and those rows are the step rows")

        let listed = brainBuilder(style: .brain, rowsShown: ["b-m1"]).rows(state: state)
        let listedBrains = listed.filter(isBrain)
        try expect(listedBrains.count == 2, "Rows keeps the brain beside the rows it lists")
        try expect(
            listed.contains(where: isStepRow) && listed.count > rows.count,
            "Rows lists the old step rows for that turn")
        let firstOfB = listed.firstIndex { $0.key == "brain:b-m1" } ?? -1
        let rowsOfA = listed[..<firstOfB].filter(isStepRow)
        try expect(rowsOfA.isEmpty, "and only for the turn that asked")

        let search = brains[1].turn.steps.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        try expect(
            rows.first { $0.key == "brain:b-m1" }?.searchText.contains("ffprobe") == true
                && search.contains("ffprobe"),
            "in-conversation find reads a brain's step titles and details")

        let builder = brainBuilder(style: .brain)
        _ = builder.rows(state: state)
        let first = builder.brainReadings
        var growing = messages
        guard var answer = growing.popLast() else { throw SelfTestFailure("brain: no answer") }
        for length in stride(from: 10, through: 60, by: 10) {
            answer.parts = [MessagePart(id: "p0", kind: .text(String(repeating: "x", count: length)))]
            answer.isStreaming = true
            _ = builder.rows(state: brainState(growing + [answer], running: true))
        }
        let after = builder.brainReadings
        let streamed = after.partitions - first.partitions
        try expect(
            streamed <= 6 + 2,
            "six streamed tokens read the turn being written and not the conversation (read \(streamed))")
        try expect(
            after.reuses - first.reuses >= 6,
            "and the turn that finished is handed back from the cache each time")
    }

    private static func checkBrainFallbacks(_ expect: (Bool, String) throws -> Void) throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-neural-empty-\(getpid())")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment[NeuralAssetFiles.variable]
        setenv(NeuralAssetFiles.variable, empty.path, 1)
        NeuralAssetFiles.forget()
        defer {
            if let saved { setenv(NeuralAssetFiles.variable, saved, 1) } else { unsetenv(NeuralAssetFiles.variable) }
            NeuralAssetFiles.forget()
            try? FileManager.default.removeItem(at: empty)
        }
        let candidates = NeuralAssetFiles.candidates()
        try expect(
            candidates.first?.path == empty.path,
            "an explicit folder is the first place the layers are looked for")
        let stillFound = NeuralAssetFiles.isAvailable
        if !stillFound {
            let before = AppLog.tail(lines: 400).components(separatedBy: "no layer set found").count - 1
            let style = Preferences.effectiveActivityStyle
            _ = Preferences.effectiveActivityStyle
            Thread.sleep(forTimeInterval: 0.3)
            let after = AppLog.tail(lines: 400).components(separatedBy: "no layer set found").count - 1
            try expect(style == .lines, "layers that are not on the machine keep the Lines style")
            try expect(after - before <= 1, "and say so once in the log, however often it is asked")
        } else {
            try expect(
                NeuralAssetFiles.directory?.path != empty.path,
                "an empty folder is not taken for a layer set")
        }
        NeuralAssetFiles.forget()
        unsetenv(NeuralAssetFiles.variable)
        if let saved { setenv(NeuralAssetFiles.variable, saved, 1) }
        NeuralAssetFiles.forget()
        try expect(
            NeuralAssetFiles.decode("/nonexistent/chassis.png") == nil,
            "a layer that cannot be read is nothing, not a trap")
    }

    private static func checkBrainWidget(_ expect: (Bool, String) throws -> Void) throws {
        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return }
        Gtk.installStyle()
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while Date() < end, g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return done()
        }

        let messages = NeuralDemo.turn(prefix: "w-", origin: Date().timeIntervalSince1970 - 600)
        let state = brainState(messages)
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: state)
        guard let row = rows.first(where: isBrain), case .brain(let brain) = row.kind else {
            throw SelfTestFailure("brain: the scripted turn made no brain row")
        }

        let host = BrainHost()
        host.sessionKey = "selftest"
        host.policy = { builder.brainPolicy }
        let context = TranscriptContext()
        context.brains = host
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1000, 800)
        let widget = BrainView.make(brain, context: context)
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(holder), widget)
        gtk_window_set_child(ptr(window), holder)
        gtk_window_present(ptr(window))
        guard let view = BrainView.current(of: widget) else {
            throw SelfTestFailure("brain: the row's widget carries no view")
        }
        try expect(view.isOpen && view.hasStage, "the open latest turn builds its stage")
        let ready = pump(15) { view.stage?.hasRenderer == true && view.stage?.hasPicture == true }
        try expect(ready, "the compositor is built off the main loop and the first picture is drawn")
        guard let stage = view.stage else { throw SelfTestFailure("brain: no stage") }

        let size = stage.size
        try expect(
            size.width > 0 && abs(Double(size.height) - Double(size.width) * 420 / 576) <= 1.5,
            "the stage keeps the head's trimmed proportions at the width it is given (\(size.width)x\(size.height))")
        try expect(
            stage.footprint > 0 && BrainCompositors.resident.compositors >= 1,
            "an open head holds one compositor and two surfaces")

        let id = view.model.steps[0].id
        let node = view.model.layout.placements[id] ?? NeuralPoint(0, 0)
        try expect(
            view.model.hit(at: node, slop: 0) == id,
            "a point on a node finds that node")
        try expect(
            view.model.hit(at: NeuralPoint(node.x + 45, node.y + 45), slop: 0) != id,
            "and a point well off it does not")

        view.hover(id)
        try expect(!view.model.hotSteps.isEmpty, "hovering a node lights the steps wired to it")
        view.hover(nil)
        view.pin(id)
        view.hover(nil)
        try expect(view.model.pinned == id, "a pinned node stays pinned when the pointer leaves")
        view.clearSelection()
        try expect(view.model.pinned == nil, "Esc or an empty click lets go of it")

        _ = pump(1.0)
        let settledTicks = tailscode_live_ticks()
        _ = pump(0.6)
        try expect(
            !view.isClockRunning && tailscode_live_ticks() == settledTicks,
            "a settled head runs no clock")

        view.toggleReplay()
        try expect(
            view.model.isReplaying && view.isClockRunning,
            "Replay starts the turn again on a clock of its own")
        _ = pump(0.8)
        try expect(
            (view.model.replayFraction(now: BrainClock.now) ?? 0) > 0.01,
            "and the playhead moves")
        view.scrub(to: 0.5)
        try expect(
            view.model.tempo(reduceMotion: false) == .display,
            "scrubbing asks for the display's own rate")
        view.endScrub()
        view.toggleReplay()
        _ = pump(0.3)
        try expect(!view.model.isReplaying && !view.isClockRunning, "stopping the replay stops the clock")

        stage.dive(into: .shell)
        try expect(stage.isDiving, "pressing a zone's name dives into it")
        _ = pump(0.9)
        try expect(!stage.isDiving && stage.diveZone == .shell, "the dive lands on the zone")
        _ = view.escapePressed()
        _ = pump(0.7)
        try expect(stage.diveZone == nil, "Esc surfaces")

        host.suspend()
        _ = pump(0.2)
        try expect(
            !stage.hasRenderer && stage.footprint == 0 && !view.isClockRunning,
            "a hidden pane owns no compositor, no surface and no clock")
        host.resume()
        try expect(
            pump(10) { stage.hasRenderer && stage.footprint > 0 },
            "and takes them again when it is shown")

        let running = brainBuilder(style: .brain)
        let runningMessages = NeuralDemo.turn(
            prefix: "r-", origin: Date().timeIntervalSince1970 - 90, answer: false)
        var live = runningMessages
        if var last = live.popLast() {
            last.isStreaming = true
            last.completedAt = nil
            live.append(last)
        }
        let liveRows = running.rows(state: brainState(live, running: true))
        guard let liveRow = liveRows.first(where: isBrain), case .brain(let liveBrain) = liveRow.kind
        else { throw SelfTestFailure("brain: no brain for a running turn") }
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        let working = BrainView.make(liveBrain, context: context)
        gtk_box_append(ptr(holder), working)
        guard let workingView = BrainView.current(of: working) else {
            throw SelfTestFailure("brain: no view for the running turn")
        }
        _ = pump(0.5)
        try expect(
            workingView.isClockRunning && workingView.model.tempo(reduceMotion: false) == .activity,
            "a turn that is working breathes on the activity clock")
        let ticksBefore = tailscode_live_ticks()
        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        _ = pump(0.4)
        try expect(
            !workingView.isClockRunning && tailscode_live_ticks() < ticksBefore,
            "reduced motion holds every state still and takes the clock off")
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        _ = pump(0.4)
        try expect(workingView.isClockRunning, "and the clock comes back when movement is allowed")

        gtk_box_remove(ptr(holder), working)
        gtk_window_set_child(ptr(window), nil)
        gtk_window_destroy(ptr(window))
        _ = pump(0.6)
        try expect(
            BrainCompositors.resident.compositors >= 1,
            "the last compositors are kept a moment for the next head to take")
        BrainCompositors.dropIdle(olderThan: 0)
        try expect(
            BrainCompositors.resident.compositors == 0 && NeuralAssetStore.shared.retainCount == 0,
            "closing the last head frees the compositor and the decoded layers")
    }

    static func brainPump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            while Date() < end, g_main_context_iteration(nil, 0) != 0 {}
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return done()
    }

    private static func settledBrain() throws -> (row: BrainRow, builder: TranscriptRowBuilder) {
        let messages = NeuralDemo.conversation()
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: brainState(messages))
        let brains = rows.compactMap { row -> BrainRow? in
            if case .brain(let brain) = row.kind { return brain }
            return nil
        }
        guard let latest = brains.last else { throw SelfTestFailure("brain: no brain row") }
        return (latest, builder)
    }

    /// The share poster: its words, its size, that the head is in the hero and not an empty box,
    /// that the two looks and the two appearances are different pictures, and that a machine with no
    /// layers still gets a hero.
    private static func checkBrainPoster(_ expect: (Bool, String) throws -> Void) throws {
        let (brain, _) = try settledBrain()
        try expect(
            brain.open && brain.prompt?.contains("product demonstration") == true,
            "the open settled brain carries the words that began its turn")
        let rows = brainBuilder(style: .brain).rows(state: brainState(NeuralDemo.conversation()))
        let earlier = rows.compactMap { row -> BrainRow? in
            if case .brain(let brain) = row.kind { return brain }
            return nil
        }.first
        try expect(earlier?.open == false && earlier?.prompt == nil, "and a closed one reads no prompt")

        let name = BrainPoster.filename(
            prompt: "Make a product demonstration .mp4", turn: brain.turn,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        try expect(
            name.hasPrefix("tailscode-turn-make-a-product-demonstration-mp4-") && name.hasSuffix(".png"),
            "a saved poster is named for the question and the day (\(name))")
        try expect(
            BrainPoster.filename(prompt: nil, turn: brain.turn).hasPrefix("tailscode-turn-"),
            "a turn with no words still gets a name")

        let model = NeuralBrainModel(turn: brain.turn, context: .none)
        let card = NeuralShare.Card.make(turn: brain.turn, prompt: brain.prompt, style: .app, dark: true)

        var fallback: PosterSurface?
        let saved = ProcessInfo.processInfo.environment[NeuralAssetFiles.variable]
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-poster-empty-\(getpid())")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        setenv(NeuralAssetFiles.variable, empty.path, 1)
        NeuralAssetFiles.forget()
        if !NeuralAssetFiles.isAvailable {
            BrainPoster.render(model: model, prompt: brain.prompt, style: .neural, dark: true, scale: 0.5) {
                fallback = $0
            }
        }
        if let saved { setenv(NeuralAssetFiles.variable, saved, 1) } else { unsetenv(NeuralAssetFiles.variable) }
        NeuralAssetFiles.forget()
        try? FileManager.default.removeItem(at: empty)
        if let fallback {
            let ground = fallback.pixel(x: card.hero.x + 6, y: card.hero.y + card.hero.height / 2)
            try expect(
                fallback.pixels(in: card.hero, notNear: ground) > 200,
                "a machine with no layers still gets a hero: the glyph drawn large")
        }

        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return }
        BrainPoster.heroWidthOverride = 320
        defer { BrainPoster.heroWidthOverride = nil }
        var made: [String: PosterSurface] = [:]
        let combos: [(String, CardStyle, Bool)] = [("app-dark", .app, true), ("neural", .neural, true)]
        for (key, look, dark) in combos {
            var poster: PosterSurface?
            var done = false
            BrainPoster.render(model: model, prompt: brain.prompt, style: look, dark: dark, scale: 1) {
                poster = $0
                done = true
            }
            _ = brainPump(60) { done }
            guard let poster else { throw SelfTestFailure("brain: no poster for \(key)") }
            made[key] = poster
        }
        guard let dark = made["app-dark"], let neural = made["neural"] else {
            throw SelfTestFailure("brain: posters missing")
        }
        try expect(
            dark.width == Int(NeuralShare.Card.width) && dark.height == Int(NeuralShare.Card.height),
            "the poster has the card's size (\(dark.width)x\(dark.height))")
        let png = dark.png
        try expect(
            (png?.count ?? 0) > 20_000 && png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
            "and encodes as a PNG a file can hold")
        let wholeCard = NeuralShare.Rect(0, 0, NeuralShare.Card.width, NeuralShare.Card.height)
        for (key, poster) in made {
            let canvas = poster.pixel(x: 3, y: 3)
            try expect(
                poster.pixels(in: wholeCard, notNear: canvas) > 20_000,
                "the \(key) poster is not blank")
            let ground = poster.pixel(x: card.hero.x + 6, y: card.hero.y + card.hero.height / 2)
            try expect(
                poster.pixels(in: card.hero, notNear: ground) > 15_000,
                "the \(key) poster's hero holds the head, not an empty box")
            if let quote = card.quote {
                try expect(
                    poster.pixels(in: quote.label.rect, notNear: canvas) > 60,
                    "the \(key) poster quotes the question")
            }
            let meterBar = card.meters.max { $0.share < $1.share }
            if let bar = meterBar?.bar {
                try expect(
                    poster.pixels(in: bar, notNear: canvas) > 200, "and draws its zone meters")
            }
        }
        try expect(
            dark.differences(from: neural) > 1_500,
            "the two looks are different pictures (\(dark.differences(from: neural)) of the sampled pixels)")
        let lightCard = NeuralShare.Card.make(turn: brain.turn, prompt: brain.prompt, style: .app, dark: false)
        try expect(
            lightCard.palette != card.palette,
            "and the app look wears its own light and dark faces")

        let remembered = BrainPoster.savedLook()
        BrainPoster.remember(.neural)
        defer { BrainPoster.remember(remembered) }
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 700, 900)
        gtk_window_present(ptr(window))
        let dialog = BrainShareDialog.present(
            model: model, prompt: brain.prompt, parent: ptr(window))
        let drawn = brainPump(60) { dialog.hasPreview }
        try expect(drawn, "the share sheet draws the poster before it leaves")
        try expect(
            dialog.offers == ["Copy", "Save…", "Close"].map { Localized.text($0) },
            "and offers Copy, Save and Close")
        dialog.close()
        gtk_window_destroy(ptr(window))
        _ = brainPump(0.4)
        BrainCompositors.dropIdle(olderThan: 0)
    }

    /// A brain opening or closing above the reader's place: the row at the top of the viewport stays
    /// where it is while the stage is built and laid out, though the page grows by the stage's height.
    private static func checkBrainAnchor(_ expect: (Bool, String) throws -> Void) throws {
        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return }
        Gtk.installStyle()
        let (brain, builder) = try settledBrain()
        var closed = brain
        closed.open = false
        var opened = brain
        opened.open = true

        func run() throws -> (opening: Double, closing: Double, grew: Double) {
            let host = BrainHost()
            host.sessionKey = "selftest-anchor"
            host.policy = { builder.brainPolicy }
            let context = TranscriptContext()
            context.brains = host
            let window = gtk_window_new()!
            gtk_window_set_default_size(ptr(window), 900, 600)
            let scroller = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
            let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
            let view = BrainView.make(closed, context: context)
            var rows: [ScrollAnchor.Row] = []
            func filler(_ key: String) {
                let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                gtk_widget_set_size_request(box, -1, 90)
                gtk_box_append(ptr(box), Gtk.label(key, css: nil, selectable: false))
                gtk_box_append(ptr(canvas), box)
                rows.append((key, UInt(bitPattern: box)))
            }
            for index in 0..<3 { filler("before-\(index)") }
            gtk_box_append(ptr(canvas), view)
            rows.append(("brain", UInt(bitPattern: view)))
            for index in 0..<14 { filler("after-\(index)") }
            gtk_scrolled_window_set_child(op(scroller), canvas)
            gtk_window_set_child(ptr(window), scroller)
            gtk_window_present(ptr(window))
            guard let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) else {
                throw SelfTestFailure("brain: the scroller has no adjustment")
            }
            _ = brainPump(0.5)
            let anchor = ScrollAnchor(
                adjustment: adjustment, canvas: canvas, rows: { rows },
                place: { gtk_adjustment_set_value(adjustment, $0) })
            Gtk.onNotify(UnsafeMutableRawPointer(adjustment), property: "upper") { anchor.reassert() }
            host.anchor = { anchor.capture() }
            func offset(of key: String) -> Double {
                guard let row = rows.first(where: { $0.key == key }),
                    let raw = UnsafeMutableRawPointer(bitPattern: row.widget)
                else { return .nan }
                var x = 0.0
                var y = 0.0
                var w = 0.0
                var h = 0.0
                _ = tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &w, &h)
                return y - gtk_adjustment_get_value(adjustment)
            }
            var brainBottom = 0.0
            if let raw = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: view)) {
                var x = 0.0
                var y = 0.0
                var w = 0.0
                var h = 0.0
                _ = tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &w, &h)
                brainBottom = y + h
            }
            gtk_adjustment_set_value(adjustment, brainBottom + 200)
            _ = brainPump(0.5)
            let before = offset(of: "after-3")
            let upperBefore = gtk_adjustment_get_upper(adjustment)
            guard let held = BrainView.current(of: view) else { throw SelfTestFailure("brain: no view") }
            held.restate(opened)
            var trail: [String] = []
            let began = Date()
            _ = brainPump(8) {
                trail.append(String(format: "%.2f:%.1f", Date().timeIntervalSince(began), offset(of: "after-3") - before))
                return held.hasStage && held.stage?.hasRenderer == true && held.phase == .open
            }
            _ = brainPump(0.6)
            let afterOpen = offset(of: "after-3")
            if abs(afterOpen - before) > 1.5 { report("brain anchor trail \(trail.suffix(40).joined(separator: " "))") }
            let grew = gtk_adjustment_get_upper(adjustment) - upperBefore
            held.restate(closed)
            _ = brainPump(0.8)
            let afterClose = offset(of: "after-3")
            gtk_window_set_child(ptr(window), nil)
            gtk_window_destroy(ptr(window))
            _ = brainPump(0.4)
            BrainCompositors.dropIdle(olderThan: 0)
            return (afterOpen - before, afterClose - before, grew)
        }

        let held = try run()
        try expect(
            held.grew > 100,
            "the stage opening above the viewport makes the page taller by its own height (\(Int(held.grew)) px)")
        try expect(
            abs(held.opening) <= 1.5,
            "and the row at the top of the viewport stays put (\(held.opening) px)")
        try expect(
            abs(held.closing) <= 1.5,
            "and again when it closes (\(held.closing) px)")
    }
}
