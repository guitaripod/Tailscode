import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The forge as this window draws it, state by state. A render is minutes of another machine's
    /// card, so the states between pressing the button and holding a file cannot be reached in a
    /// build loop — and they are exactly the ones worth checking, because each of them is a
    /// different sentence and each of them draws a different row. Every value asserted here is
    /// Core's: what this proves is that the pane can be put into the state and that the row it
    /// builds carries the words, the badge, the bar and the reach the board handed it.
    static func checkForgeSurface() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("forge surface: \(label)") }
            checks += 1
        }
        func jobRow(_ board: ForgeBoard) throws -> ForgeRow {
            guard let row = board.rows.first(where: { $0.kind == .job }) else {
                throw SelfTestFailure("forge surface: the render has no row")
            }
            return row
        }
        func section(_ board: ForgeBoard, _ id: String) throws -> ForgeSection {
            guard let section = board.sections.first(where: { $0.id == id }) else {
                throw SelfTestFailure("forge surface: no \(id) section")
            }
            return section
        }

        for name in ForgeDemo.states {
            let board = ForgeDemo.board(name)
            try expect(
                board.sections.map(\.id).starts(
                    with: [ForgeBoard.rendererID, ForgeBoard.renderID, ForgeBoard.settingsID]),
                "\(name) draws the renderer, the render and the settings, in that order")
            try expect(!board.notice.isEmpty, "\(name) still says where a render happens")
        }

        var unset = ForgeDemo.board("unset")
        try expect(
            unset.renderCall == Localized.text("Set up the renderer"),
            "with no machine, the button says it would go and get one")
        try expect(unset.begin() == .configure, "and pressing it asks for the address")
        try expect(
            unset.value(of: .endpoint) == Localized.text("Not set up yet"),
            "while the row says there is none")

        let checking = ForgeDemo.board("checking")
        try expect(checking.isChecking, "a machine being asked is a state of its own")
        try expect(try section(checking, ForgeBoard.rendererID).phase == .checking, "and its section says so")
        try expect(try section(checking, ForgeBoard.rendererID).rows.first?.badge == nil,
            "a machine mid-question wears no word yet")

        let down = ForgeDemo.board("down")
        try expect(
            try section(down, ForgeBoard.rendererID).rows.first?.detail
                == ForgeEndpoint.sentence(for: .timedOut, host: ForgeDemo.host),
            "a machine that did not answer says so in Core's own sentence")
        try expect(
            try section(down, ForgeBoard.rendererID).rows.first?.badge == Localized.text("down"),
            "and wears the word for it")

        var ready = ForgeDemo.board("ready")
        try expect(try jobRow(ready).detail == Localized.text("Ready to render"), "a described draft is ready")
        try expect(ready.renderCall == Localized.text("Render"), "and the button says what it would do")
        try expect(ready.canRender, "and it can")
        try expect(ready.begin() == .render(ready.recipe), "on exactly what is on the board")

        let waking = ForgeDemo.board("waking")
        try expect(try jobRow(waking).badge == Localized.text("waking"), "the twelve-second wake has a word")
        try expect(try jobRow(waking).fraction == nil, "and no bar, because there is nothing honest to fill")

        let queued = ForgeDemo.board("queued")
        try expect(try jobRow(queued).badge == Localized.text("queued"), "a queued render says so")
        try expect(
            try jobRow(queued).detail == Localized.text("%@ ahead in the queue", "2"),
            "and how many are ahead of it")
        try expect(try jobRow(queued).fraction == nil, "still with no bar")

        var running = ForgeDemo.board("running")
        try expect(try jobRow(running).fraction == 0.5, "a running render carries the node census as its bar")
        try expect(try jobRow(running).badge == Localized.text("50%"), "and the same number in the corner")
        try expect(
            try jobRow(running).note?.contains(Localized.text("step %@ of %@", "3", "4")) == true,
            "the sampler's own step is said in words, never as the bar")
        try expect(running.renderCall == Localized.text("Stop"), "and the button stops it")
        try expect(running.begin() == .cancel, "which is what pressing it does")
        try expect(
            running.rows.first(where: { $0.kind == .field(.size) })?.isActivatable == false,
            "the settings the render already consumed are out of reach")

        let collecting = ForgeDemo.board("collecting")
        try expect(
            try jobRow(collecting).detail == Localized.text("Saving the file…"),
            "a full bar with no file yet is a state with its own words")
        try expect(try jobRow(collecting).badge == Localized.text("saving"), "and its own word")

        var done = ForgeDemo.board("done")
        try expect(try jobRow(done).badge == Localized.text("ready"), "a delivered render says it is ready")
        try expect(done.renderCall == Localized.text("Play"), "and the button plays it")
        try expect(done.begin() == .play(ForgeDemo.asset), "on the file that came back")

        let failed = ForgeDemo.board("failed")
        try expect(
            try jobRow(failed).detail == "UNETLoader failed: CUDA out of memory",
            "a render that failed says why rather than going quiet")
        try expect(try jobRow(failed).badge == Localized.text("failed"), "with a word in the corner")
        try expect(try section(failed, ForgeBoard.renderID).phase == .failed("UNETLoader failed: CUDA out of memory"),
            "and the whole section wears the failure")

        let stopped = ForgeDemo.board("stopped")
        try expect(try jobRow(stopped).detail == Localized.text("Stopped"), "a cancelled render says only that")
        try expect(try jobRow(stopped).badge == Localized.text("stopped"), "and holds still")

        var empty = ForgeDemo.board("empty")
        guard let note = empty.rows.firstIndex(where: { $0.kind == .note }) else {
            throw SelfTestFailure("forge surface: an empty history drew nothing at all")
        }
        try expect(
            empty.rows[note].title == Localized.text("Nothing rendered yet"),
            "an empty history says it is empty rather than vanishing")
        empty.focus(note)
        try expect(empty.cursor != note, "and the cursor does not stop on it")

        let history = ForgeDemo.board("history")
        let kept = try section(history, ForgeBoard.historyID)
        try expect(kept.rows.count == ForgeBoard.compactLimit + 1, "a long history compacts")
        try expect(kept.hidden == 3, "and says how many it is holding back")
        guard let lost = history.rows.first(where: { $0.entry?.isPlayable == false }) else {
            throw SelfTestFailure("forge surface: the history lost its unplayable row")
        }
        try expect(lost.badge == Localized.text("failed"), "a clip that never arrived says so")
        try expect(lost.detail == ForgeFailure.noOutput(ForgeDemo.host).description, "and keeps the reason")

        let mark = ForgeMarkButton(target: nil, action: #selector(NSApplication.terminate(_:)))
        mark.render()
        try expect(
            mark.image != nil, "the toolbar's way in wears the symbol every client wears for it")
        try expect(
            mark.toolTip
                == ForgeEntryPoint.tooltip(
                    configured: ForgeRunner.shared.endpoint != nil, light: ForgeRunner.shared.light),
            "and promises what Core says it promises")
        try expect(
            mark.accessibilityLabel() == ForgeEntryPoint.accessibilityLabel(light: ForgeRunner.shared.light),
            "reading out the same words a tooltip nobody hears would have said")
        try expect(
            !mark.subviews.contains { $0 is ActivityBadgeView },
            "the control wears a ring of light and no badge beside it")

        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        let watching = ForgeRunner.shared.watcherCount
        host.contentView?.addSubview(mark)
        try expect(
            ForgeRunner.shared.watcherCount == watching + 1,
            "a control on screen is called back, so its badge follows the render")
        mark.removeFromSuperview()
        try expect(
            ForgeRunner.shared.watcherCount == watching,
            "and lets go the moment it leaves, rather than being called for the life of the process")

        let lane = VideoLane(runner: ForgeRunner.shared)
        try expect(
            ForgeRunner.shared.watcherCount == watching + 1,
            "the Video lane watches the runner, which is what keeps a render in view after the Studio closes")
        _ = lane.stage
        try expect(
            lane.id == .video && lane.shelfTitle == Localized.text("Clips"),
            "the lane is the second of the Studio's two, and its shelf is clips")

        try expect(
            ForgeSurface.preferredWidth >= ForgeSurface.minimumWidth
                && ForgeSurface.preferredHeight >= ForgeSurface.minimumHeight,
            "the modal opens no smaller than it is allowed to be shrunk to")
        try expect(
            ForgeSurface.dismissNote(rendering: false) == nil,
            "closing over nothing needs no reassurance")
        try expect(
            ForgeSurface.dismissNote(rendering: true) != nil,
            "and closing over a render says the render keeps going")
        return checks
    }

    /// A page is a pane, so what it holds has to read back the same after a restart, and a browsing
    /// pane must leave the keyboard to the page except for the chords a browser owns.
    static func checkBrowserSlot() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("browser slot: \(label)") }
            checks += 1
        }

        try expect(WebTarget.classify("swift.org") == .page("https://swift.org"), "a host is a page")
        try expect(WebTarget.classify(":3000") == .page("http://localhost:3000"), "a port is local")
        try expect(
            WebTarget.classify("localhost:8080/health") == .page("http://localhost:8080/health"),
            "a local path is kept")
        try expect(
            WebTarget.classify("how to split a pane") == .search("how to split a pane"),
            "words are a search")
        try expect(WebTarget.classify("  ") == nil, "nothing typed points nowhere")
        try expect(
            WebTarget.search("two words").url.hasPrefix("https://duckduckgo.com/?q="),
            "a search is a real page")

        var slot = WebSlot()
        try expect(slot.isAsking, "an empty slot asks")
        slot.point(at: .page("https://swift.org"))
        slot.arrived(url: "https://www.swift.org/", title: "Swift Programming Language")
        try expect(slot.phase == .showing, "a landed page shows")
        try expect(slot.title == "Swift Programming Language", "the page names the pane")
        slot.ask()
        try expect(slot.draft == "https://www.swift.org/", "the address bar opens on where it is")

        var layout = SplitLayout()
        let first = layout.focusedPane
        guard let second = layout.split(first, axis: .vertical) else {
            throw SelfTestFailure("browser slot: the layout would not split")
        }
        let snapshot = SplitSnapshot(
            layout: layout, sessions: [:], videos: [:],
            pages: [second.raw: "https://swift.org/documentation/"])
        guard let encoded = snapshot.encoded, let restored = SplitSnapshot.decode(encoded) else {
            throw SelfTestFailure("browser slot: the layout would not persist")
        }
        try expect(
            restored.page(for: second) == .page("https://swift.org/documentation/"),
            "a restart reopens the page")

        guard let plain = KeyChord.canonical(keyval: 0x61, state: 0),
            let address = KeyChord.canonical(keyval: 0x6C, state: KeyChord.controlMask),
            let back = KeyChord.canonical(keyval: 0xFF51, state: KeyChord.altMask)
        else { throw SelfTestFailure("browser slot: a keystroke would not resolve") }
        try expect(WebCommand.command(for: plain) == nil, "a letter belongs to the page")
        try expect(WebCommand.command(for: address) == .address, "ctrl+l opens the address bar")
        try expect(WebCommand.command(for: back) == .back, "alt+left goes back")
        return checks
    }

    /// The repository surface where it can actually go wrong on this toolkit: the shared reading
    /// of a working tree must survive being drawn — a panel that cannot build its own view is a
    /// popover that opens empty — and a patch must reach AppKit with its meanings still apart.
    static func checkGit() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("git: \(label)") }
            checks += 1
        }
        let snapshot = GitSnapshot(
            root: "/home/dev/project", branch: "master", head: "abc12345",
            upstream: "origin/master", ahead: 2, behind: 1, stashes: 1, operation: "rebase",
            remote: "git@github.com:acme/project.git",
            changes: [
                GitChange(
                    path: "Sources/App/Main.swift", index: "M", worktree: "M", insertions: 3,
                    deletions: 1, stagedInsertions: 8, stagedDeletions: 2),
                GitChange(
                    path: "docs/", worktree: "?", untracked: true, directory: true, contains: 4),
                GitChange(path: "Package.swift", index: "U", worktree: "U", conflicted: true),
            ],
            commits: [
                GitCommitSummary(
                    hash: "deadbeefcafe", short: "deadbeef", subject: "a change", author: "dev",
                    at: Date(timeIntervalSince1970: 1_700_000_000), refs: ["HEAD -> master"])
            ], changedTotal: 3)
        let state = GitState(snapshot: snapshot)
        try expect(
            state.sections.map(\.kind) == [.conflicts, .staged, .changed, .untracked],
            "sections triage in order")
        try expect(state.alert?.contains("Rebase") == true, "an unfinished rebase leads the header")
        try expect(
            state.badge.contains("↑2") && state.badge.contains("↓1"),
            "the chip carries both drifts")
        try expect(
            state.facts.contains { $0.value == "acme/project" },
            "the remote is named the way a person names it")

        let panel = GitPanelViewController(
            state: state, title: "a chat", patch: { _ in nil }, commit: { _ in nil },
            openDiff: { _, _, _ in })
        try expect(panel.view.subviews.count == 1, "the panel builds its own view")

        let parts = state.badgeParts
        try expect(parts.first?.tone == .neutral, "the branch is drawn as a state")
        try expect(Set(parts.map(\.tone)).count >= 4, "the chip's marks share one colour")
        try expect(
            parts.map(\.text).joined(separator: " ") == state.badge,
            "the runs and the plain chip say different things")
        var badgeInks: Set<String> = []
        let tinted = GitPanelViewController.tinted(state.summaryParts, font: MacTheme.Ramp.font(.panelFootnote))
        tinted.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: tinted.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { badgeInks.insert(CascadeTint.hex(colour)) }
        }
        try expect(badgeInks.count >= 3, "the working-tree line is written in one colour")

        let rendered = GitDiffWindowController.render(
            """
            diff --git a/a.swift b/a.swift
            @@ -10,2 +10,2 @@
             kept
            -gone
            +arrived
            """)
        var colours: Set<String> = []
        rendered.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: rendered.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { colours.insert(CascadeTint.hex(colour)) }
        }
        try expect(colours.count >= 3, "a patch reaches AppKit with its meanings apart")
        try expect(
            rendered.string.contains("+ arrived") && rendered.string.contains("− gone"),
            "both sides of the change are drawn")
        return checks
    }
}
