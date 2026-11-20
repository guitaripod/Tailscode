import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore
import os

/// `--bench experts-check`: the experts audit alone, under a running application with nothing on
/// screen, so it can be run (and its pictures drawn with `TAILSCODE_EXPERTS_OUT`) without the whole
/// self-test and its clock.
@MainActor
enum ExpertChecks {
    nonisolated static let spec = "experts-check"

    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let checks = try await SelfTest.checkExperts()
                print("EXPERTS_OK \(checks)")
                exit(0)
            } catch {
                print("EXPERTS_FAILED \(error)")
                exit(1)
            }
        }
        app.run()
        exit(1)
    }
}

extension SelfTest {
    /// Experts over the demo world's machine: the desk reads every expert, the sidebar's place
    /// lists them in Core's words with the notes waiting, the Experts window draws a page with the
    /// bench, the guards, the notebook and the journal the machine answers, the task sheet says what
    /// a task starts with and refuses an empty task, a task started reaches the machine as a
    /// conversation marked as the expert's, and the debrief at a task's end names each proposal's
    /// own action, accepts one, skips the rest, and settles.
    static func checkExperts() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            if !condition { throw SelfTestFailure(label) }
            checks += 1
        }
        let desk = ExpertDesk.shared
        desk.stageDemo()
        await MachineDesk.shared.refresh()
        await desk.refresh()
        let demo = DemoWorld.claudeProfile
        try expect(desk.keepsExperts(demo.id), "the demo machine keeps experts")
        try expect(desk.board.rows.count == 3, "three demo experts, got \(desk.board.rows.count)")
        guard let ipad = desk.board.rows.first(where: { $0.expert.name == "iPadOS" }),
            let server = desk.board.rows.first(where: { $0.expert.name == "Server" }),
            let releases = desk.board.rows.first(where: { $0.expert.name == "Releases" })
        else { throw SelfTestFailure("the demo's three experts by name") }
        try expect(ipad.expert.pending == 3, "iPadOS waits on three notes, got \(ipad.expert.pending)")
        try expect(server.state().tone == .active, "Server is at work: \(server.state().text)")
        try expect(releases.state().tone == .failing, "Releases has a guard failing: \(releases.state().text)")

        let entry = ExpertsSidebarEntry()
        entry.render()
        try expect(!entry.isHidden, "the sidebar's Experts place shows while a machine keeps experts")
        try expect(entry.shownNames.count == 3, "the place lists every expert: \(entry.shownNames)")
        try expect(
            entry.shownStates.contains(ipad.state().text), "a row says the shelf's line: \(entry.shownStates)")
        try expect(
            entry.headerBadge == "\(desk.board.pending)",
            "the place's badge counts every note waiting, listed rows too: \(entry.headerBadge ?? "none")")

        let window = ExpertsWindow()
        window.window?.setFrameAutosaveName("")
        window.window?.setFrameOrigin(NSPoint(x: -6_000, y: -6_000))
        window.present(selecting: ipad.id)
        try expect(window.shownRows.count == 3, "the window lists every expert")
        try expect(window.selectedRow?.expert.id == ipad.expert.id, "the chosen expert is the one on the right")
        for _ in 0..<60 where window.page.noteTitles.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(window.page.headName == "iPadOS", "the page is the expert's")
        try expect(
            window.page.sectionTitles.contains(ExpertWords.bench.uppercased(with: .current))
                && window.page.sectionTitles.contains(ExpertWords.notebook.uppercased(with: .current)),
            "the page has its bench and its notebook: \(window.page.sectionTitles)")
        try expect(
            window.page.benchLines.contains {
                $0.hasPrefix("iPhone Air")
                    && $0.hasSuffix(
                        ExpertReading.benchLine(ExpertBenchItem(name: "", kind: .appleDevice, state: .locked), machine: "").text)
            },
            "a locked device says so: \(window.page.benchLines)")
        try expect(window.page.noteTitles.count == 6, "the notebook lists the live notes: \(window.page.noteTitles)")
        try expect(
            window.page.guardLines.first?.hasPrefix("4 of 4") == true || window.page.guardLines.count >= 4,
            "the guards say how many pass: \(window.page.guardLines)")
        try dumpExperts(window.window?.contentView, "experts-ipados")
        let pageAmbiguity = ambiguous(in: window.window?.contentView)
        try expect(pageAmbiguity.isEmpty, "the Experts window lays out with nothing ambiguous: \(pageAmbiguity)")
        try expect(window.isWatching, "an open Experts window keeps the bench's five-minute proof running")
        try await checkQuietReads(window, desk: desk, expect: expect)
        try await checkAppearanceSwitch(window, expect: expect)
        try await checkSkillMenu(window, expect: expect)
        window.window?.setContentSize(NSSize(width: 720, height: 480))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.page.layoutSubtreeIfNeeded()
        try expect(
            window.page.headButtonsUnder && window.page.headWordsWidth >= 150,
            "at the window's minimum the verbs go under the words and leave them \(Int(window.page.headWordsWidth)) pt")
        let minimumAmbiguity = ambiguous(in: window.window?.contentView)
        try expect(minimumAmbiguity.isEmpty, "the page at its minimum lays out with nothing ambiguous: \(minimumAmbiguity)")
        try dumpExperts(window.window?.contentView, "experts-minimum")
        window.window?.setContentSize(NSSize(width: 1_120, height: 740))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.page.layoutSubtreeIfNeeded()
        try expect(!window.page.headButtonsUnder, "a wide page keeps the verbs beside the words")
        window.window?.setContentSize(NSSize(width: 820, height: 700))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.page.layoutSubtreeIfNeeded()
        try expect(
            !window.page.isTwoColumns,
            "a narrow window stacks the page in one column: page \(window.page.bounds.width), window \(window.window?.frame.width ?? 0)")
        let narrowAmbiguity = ambiguous(in: window.window?.contentView)
        try expect(narrowAmbiguity.isEmpty, "the one-column page lays out with nothing ambiguous: \(narrowAmbiguity)")
        try dumpExperts(window.window?.contentView, "experts-narrow")
        window.window?.setContentSize(NSSize(width: 1_120, height: 740))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.select(id: releases.id)
        try dumpExperts(window.window?.contentView, "experts-releases")
        try expect(
            window.page.guardLines.contains { $0.hasPrefix("Changelog matches the tag") },
            "a failing guard is listed: \(window.page.guardLines)")

        let host = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 760, height: 620), styleMask: [.titled],
            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        defer { host.close() }
        var started: ExpertTaskStarted?
        let sheet = ExpertTaskSheet.present(on: host, row: ipad) { _, made in started = made }
        try expect(sheet.chipTexts.contains(Localized.text("Its charter")), "a task starts with its charter")
        sheet.type("Make the composer reachable with one thumb.")
        try dumpExperts(sheet.sheet.contentView, "experts-task")
        let taskAmbiguity = ambiguous(in: sheet.sheet.contentView)
        try expect(taskAmbiguity.isEmpty, "the task sheet lays out with nothing ambiguous: \(taskAmbiguity)")
        sheet.type("")
        try expect(sheet.chipTexts.contains(ExpertWords.skill("ipados")), "a task names the skills it loads")
        try expect(!sheet.canStart, "an empty task cannot start")
        sheet.type("Make the composer reachable with one thumb.")
        try expect(sheet.canStart, "a task with words can start")
        sheet.start()
        for _ in 0..<80 where started == nil { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(started?.session.expertID == ipad.expert.id, "the task is a conversation marked as the expert's")

        let carried = ExpertTaskSheet.present(
            on: host, row: server,
            carry: ConversationBrief(source: "Bridge restart wording", body: "Earlier words.", kept: 2, total: 2, pictures: 0)
        ) { _, _ in }
        try expect(carried.canStart, "a handed-over conversation can start with no words of its own")
        host.endSheet(carried.sheet)

        guard let keeping = desk.keeping(for: demo.id),
            let debrief = try await keeping.expertDebrief(sessionID: "demo-c3")
        else { throw SelfTestFailure("the demo's open debrief") }
        let slot = ExpertDebriefSlot()
        slot.stage(debrief, row: ipad)
        let slotHost = NSWindow(
            contentRect: NSRect(x: -6_000, y: -6_000, width: 640, height: 520), styleMask: [.titled],
            backing: .buffered, defer: false)
        slotHost.isReleasedWhenClosed = false
        let slotColumn = FillingStack(topDown: false)
        slotColumn.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        slotColumn.addArrangedSubview(slot)
        slotHost.contentView = slotColumn
        slotHost.orderFront(nil)
        defer { slotHost.close() }
        try dumpExperts(slotHost.contentView, "experts-debrief")
        let slotAmbiguity = ambiguous(in: slotHost.contentView)
        try expect(slotAmbiguity.isEmpty, "the debrief card lays out with nothing ambiguous: \(slotAmbiguity)")
        try expect(
            slot.headlineText == ExpertReading.debriefHeadline(debrief, name: "iPadOS").text,
            "the card's headline is Core's: \(slot.headlineText)")
        try expect(
            slot.actionTitles == [ExpertWords.accept(.add), ExpertWords.accept(.add), ExpertWords.accept(.retire)],
            "each proposal names its own action: \(slot.actionTitles)")
        let settled = try await keeping.decideExpertDebrief(
            sessionID: "demo-c3", ExpertDebriefDecision(accepted: [debrief.proposals[0].id]))
        try expect(settled.state == .settled, "accepting one and skipping the rest settles the debrief")
        try expect(
            settled.proposals.map(\.state) == [.accepted, .skipped, .skipped],
            "only the accepted proposal reaches the notebook: \(settled.proposals.map(\.state))")
        let notes = try await keeping.expertNotes(ipad.expert.id, retired: false)
        try expect(notes.first?.title == debrief.proposals[0].title, "the accepted note is in the notebook")

        let pane = ExpertDebriefSlot()
        let taskEntry = SessionEntry(
            profileID: demo.id, profileName: demo.name, host: demo.name, backendType: .claudeCode,
            session: AgentSession(
                id: started?.session.id ?? "none", agentType: .claudeCode, title: "t", createdAt: Date(),
                updatedAt: Date(), expertID: ipad.expert.id))
        pane.bind(taskEntry, backend: desk.backend(for: demo.id))
        pane.noteState(running: false)
        for _ in 0..<40 where !pane.offersFinish { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(pane.offersFinish, "a task at rest with no debrief offers Finish task")
        pane.finish()
        let plainFirst = SessionEntry(
            profileID: demo.id, profileName: demo.name, host: demo.name, backendType: .claudeCode,
            session: AgentSession(id: "demo-c4", agentType: .claudeCode, title: "t", createdAt: Date(), updatedAt: Date()))
        pane.bind(plainFirst, backend: desk.backend(for: demo.id))
        try? await Task.sleep(for: .milliseconds(300))
        try expect(
            pane.debriefSession == nil && pane.isHidden,
            "a reply to a press in one task never lands in the chat the pane moved to: \(pane.debriefSession ?? "none")")
        pane.stop()
        try expect(!pane.isFollowing, "a pane that lets go follows no debrief")

        let plain = SessionEntry(
            profileID: demo.id, profileName: demo.name, host: demo.name, backendType: .claudeCode,
            session: AgentSession(id: "demo-c4", agentType: .claudeCode, title: "t", createdAt: Date(), updatedAt: Date()))
        let quiet = ExpertDebriefSlot()
        quiet.bind(plain, backend: desk.backend(for: demo.id))
        quiet.noteState(running: false)
        try expect(quiet.isHidden, "a chat that is no expert's task has no end to show")

        let chooser = ModelChooserSheet.present(
            on: host, sources: [], selected: nil, experts: desk.board.rows, onExpert: { _ in }) { _ in }
        try expect(chooser.offeredExperts.count == 3, "the chooser offers every expert above the models")
        chooser.dismiss()

        let entryHost = NSWindow(
            contentRect: NSRect(x: -6_000, y: -6_000, width: 280, height: 260), styleMask: [.titled],
            backing: .buffered, defer: false)
        entryHost.isReleasedWhenClosed = false
        let entryColumn = FillingStack(topDown: false)
        entryColumn.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        entryColumn.addArrangedSubview(entry)
        entryHost.contentView = entryColumn
        entryHost.orderFront(nil)
        defer { entryHost.close() }
        try dumpExperts(entryHost.contentView, "experts-sidebar")
        let editor = ExpertEditorSheet.present(on: host, profile: demo, editing: ipad.expert) { _ in }
        try dumpExperts(editor.sheet.contentView, "experts-editor")
        let editorAmbiguity = ambiguous(in: editor.sheet.contentView)
        try expect(editorAmbiguity.isEmpty, "the editor lays out with nothing ambiguous: \(editorAmbiguity)")
        try expect(editor.unnamedControls.isEmpty, "every field and menu of the form has a name: \(editor.unnamedControls)")
        if let green = editor.swatchViews.first(where: { $0.hue == .green }) {
            try expect(
                green.accessibilityLabel() == ExpertHue.green.name && green.accessibilityPerformPress()
                    && editor.chosenHue == .green && (green.accessibilityValue() as? NSNumber)?.boolValue == true,
                "a colour is named, pressed and said to be chosen without a mouse")
        } else {
            throw SelfTestFailure("the editor offers every colour")
        }
        host.endSheet(editor.sheet)
        try await checkDraftingSheetLetsGo(host, expect: expect)
        let mark = ExpertMarkView.image(ipad, side: 16)
        try expect(mark.size == NSSize(width: 16, height: 16), "an expert's mark draws at any size")
        if case .implemented = ParityManifest.evidence(for: .experts) {
            checks += 1
        } else {
            throw SelfTestFailure("the Mac answers experts")
        }
        window.close()
        try expect(!window.isWatching, "a closed Experts window asks no machine anything")
        return checks
    }

    /// A read that finds nothing new tells nobody, and a page drawn again with nothing new keeps
    /// every row it had and the charter's own field, so a selection in it lives.
    private static func checkQuietReads(
        _ window: ExpertsWindow, desk: ExpertDesk, expect: (Bool, String) throws -> Void
    ) async throws {
        try? await Task.sleep(for: .milliseconds(300))
        let drawn = window.page.drawnRows
        let told = OSAllocatedUnfairLock(initialState: 0)
        let listening = NotificationCenter.default.addObserver(
            forName: ExpertDesk.didChange, object: nil, queue: nil
        ) { _ in told.withLock { $0 += 1 } }
        await desk.refresh()
        NotificationCenter.default.removeObserver(listening)
        let posts = told.withLock { $0 }
        try expect(posts == 0, "a read that found nothing new tells nobody, told \(posts)")
        window.reload()
        try expect(window.page.drawnRows == drawn, "a page drawn again with nothing new keeps its rows and its charter")
    }

    /// Light to dark and back with the window open: the cards take the new appearance's fill.
    private static func checkAppearanceSwitch(
        _ window: ExpertsWindow, expect: (Bool, String) throws -> Void
    ) async throws {
        defer { window.window?.appearance = nil }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            guard let appearance = NSAppearance(named: name) else { continue }
            window.window?.appearance = appearance
            window.window?.contentView?.layoutSubtreeIfNeeded()
            window.window?.displayIfNeeded()
            var want: CGColor?
            appearance.performAsCurrentDrawingAppearance { want = MacTheme.Color.canvasRaised.cgColor }
            for _ in 0..<20 where window.page.benchCardFill != want { try? await Task.sleep(for: .milliseconds(25)) }
            try expect(window.page.benchCardFill == want, "a card takes the \(name.rawValue) fill when the appearance switches")
        }
    }

    /// New expert ▸ From a skill reads the machine's skills and fills the open submenu with them.
    private static func checkSkillMenu(_ window: ExpertsWindow, expect: (Bool, String) throws -> Void) async throws {
        guard let menu = window.newMenu else { throw SelfTestFailure("the window offers New expert") }
        window.menuNeedsUpdate(menu)
        guard let skills = menu.items.first(where: { $0.title == ExpertWords.makeFromSkill })?.submenu else {
            throw SelfTestFailure("New expert offers From a skill")
        }
        let reading = Localized.text("Reading the machine's skills…")
        for _ in 0..<60 where skills.items.first?.title == reading { try? await Task.sleep(for: .milliseconds(50)) }
        try expect(
            !skills.items.isEmpty && skills.items.first?.title != reading,
            "the open submenu fills with the machine's skills: \(skills.items.map(\.title))")
    }

    /// A drafting sheet that is cancelled goes, with everything it held.
    private static func checkDraftingSheetLetsGo(_ host: NSWindow, expect: (Bool, String) throws -> Void) async throws {
        weak var drafting: NSWindow?
        do {
            ExpertDraftingSheet.present(
                on: host, title: "t", detail: "d",
                work: {
                    try await Task.sleep(for: .seconds(30))
                    return ExpertDraft(name: "")
                }
            ) { _ in }
            drafting = host.attachedSheet
            let cancel = drafting?.contentView.flatMap { root -> NSButton? in
                var queue = [root]
                while let view = queue.popLast() {
                    if let button = view as? NSButton, button.title == ExpertWords.cancel { return button }
                    queue.append(contentsOf: view.subviews)
                }
                return nil
            }
            cancel?.performClick(nil)
        }
        for _ in 0..<40 where drafting != nil { try? await Task.sleep(for: .milliseconds(25)) }
        try expect(drafting == nil, "a cancelled drafting sheet is let go")
    }

    /// With `TAILSCODE_EXPERTS_OUT=<dir>` set, a surface drawn to a picture in both appearances, so
    /// the look can be read without a screen.
    private static func dumpExperts(_ view: NSView?, _ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TAILSCODE_EXPERTS_OUT"], let view else { return }
        let hadLayer = view.wantsLayer
        view.wantsLayer = true
        let kept = view.layer?.backgroundColor
        defer {
            view.layer?.backgroundColor = kept
            view.wantsLayer = hadLayer
            view.window?.appearance = nil
            view.appearance = nil
        }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            view.window?.appearance = NSAppearance(named: appearance)
            view.appearance = NSAppearance(named: appearance)
            view.layer?.backgroundColor =
                (suffix == "dark" ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor
            view.layoutSubtreeIfNeeded()
            view.window?.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    /// Every view under `root` whose place Auto Layout cannot decide, by type, for a harness.
    private static func ambiguous(in root: NSView?) -> [String] {
        guard let root else { return [] }
        root.layoutSubtreeIfNeeded()
        var found: [String] = []
        var queue = [root]
        while let view = queue.popLast() {
            let name = String(describing: type(of: view))
            if !view.isHidden, !name.hasPrefix("_"), view.hasAmbiguousLayout {
                let text = (view as? NSTextField)?.stringValue.prefix(24) ?? ""
                found.append("\(name)[\(text)] in \(view.superview.map { String(describing: type(of: $0)) } ?? "-")")
                if ProcessInfo.processInfo.environment["TAILSCODE_EXPERTS_WHY"] != nil {
                    print("AMBIGUOUS \(name) \(view.frame) h=\(view.constraintsAffectingLayout(for: .horizontal)) v=\(view.constraintsAffectingLayout(for: .vertical))")
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}
