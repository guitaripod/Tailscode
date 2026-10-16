import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The preview pane drawn from hand-built states: every face it can wear, the picture decoded
    /// from real JPEG bytes, the address the driver and the asking pane read, and the promise that
    /// a pane which is parked or shut down owns no frame clock.
    static func checkPreviewPane() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("preview: \(label)") }
            checks += 1
        }
        let target = PreviewTarget(host: "mac.local", project: PreviewFixtures.project)

        let asking = PreviewPane(target: nil)
        try expect(asking.summary == "asking", "a pane with no target asks")
        try expect(asking.isAsking && !asking.hasTick, "asking owns no clock")

        let pane = PreviewPane(target: target, runs: false)
        try expect(pane.summary.hasPrefix("connecting"), "a pointed pane with nothing heard is connecting")

        pane.applyForTest(try fixture("setup"))
        try expect(pane.summary == "settingUp rows=6", "the checklist draws every row: \(pane.summary)")

        pane.applyForTest(try fixture("starting"))
        try expect(
            pane.summary == "starting [Building your app]", "starting says its line: \(pane.summary)")

        pane.applyForTest(try fixture("live"), jpeg: PreviewFixtures.tinyJPEG)
        try expect(pane.summary == "live 12x26", "a live pane carries the picture's size: \(pane.summary)")
        try expect(
            pane.lastPictureJPEG == PreviewFixtures.tinyJPEG, "the bytes kept are the bytes decoded")

        pane.applyForTest(try fixture("reconnecting"))
        try expect(
            pane.summary == "reconnecting 12x26", "a dropped link keeps the last picture: \(pane.summary)")

        pane.applyForTest(try fixture("broken"))
        try expect(
            pane.summary == "broken 12x26 banner=NoteView.swift:42: cannot find 'noteTitle' in scope",
            "a failed build keeps the last good frame under a banner: \(pane.summary)")

        pane.applyForTest(try fixture("live"), jpeg: Data([0, 1, 2, 3]))
        try expect(
            pane.summary == "live 12x26", "bytes that do not decode never replace the last good picture")

        pane.applyForTest(try fixture("broken"))
        pane.handle(.rebuild)
        try expect(pane.slot.appearance == "light", "a rebuild does not touch the appearance")
        pane.handle(.toggleAppearance)
        try expect(pane.slot.appearance == "dark", "the toggle flips the slot's appearance")
        pane.handle(.toggleAppearance)
        try expect(pane.slot.appearance == "light", "and flips it back")

        let parsed = MainWindow.previewTarget(from: "127.0.0.1:4300:/Users/marcus/pvtest/PhotoNotes")
        try expect(
            parsed == PreviewTarget(host: "127.0.0.1", port: 4300, project: "/Users/marcus/pvtest/PhotoNotes"),
            "the driver's address reads as a target")
        try expect(MainWindow.previewTarget(from: "") == nil, "an empty driver address asks")
        try expect(PreviewPane.split("mac.local:4301") == ("mac.local", 4301), "host and port split")
        try expect(PreviewPane.split("mac.local").port == nil, "a bare host keeps the default port")

        let base = tailscode_live_ticks()
        let live = PreviewPane(
            target: PreviewTarget(host: "127.0.0.1", port: 1, project: "/nowhere"), runs: true)
        try expect(live.hasTick && live.isRunning, "a running pane owns its clock while it waits")
        try expect(tailscode_live_ticks() == base + 1, "and exactly one")
        live.park()
        try expect(!live.hasTick && !live.isRunning, "a parked pane owns no clock and no stream")
        try expect(tailscode_live_ticks() == base, "the display holds nothing for it")
        live.unpark()
        try expect(live.hasTick && live.isRunning, "shown again it takes its clock back")
        live.shutdown()
        try expect(!live.hasTick && !live.isRunning, "a shut-down pane owns neither")
        try expect(tailscode_live_ticks() == base, "the display holds nothing after shutdown")
        pane.shutdown()
        asking.shutdown()
        checks += try checkPreviewLenses()
        checks += try checkPreviewTouch()
        return checks
    }

    /// The lenses over the picture drawn from hand-built data: where an outline lands at two
    /// widths, that the handle moves the clip, one cell per variant, exactly the late frames on
    /// the scrubber, and that a lens left or a pane parked leaves no picture, tick or task.
    static func checkPreviewLenses() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("preview: lenses: \(label)") }
            checks += 1
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.01 }
        let tiny = PreviewFixtures.tinyJPEG
        let pane = PreviewPane(
            target: PreviewTarget(host: "mac.local", project: PreviewFixtures.project), runs: false)
        guard let live = PreviewFixtures.state("live") else { throw SelfTestFailure("preview: no live fixture") }
        pane.applyForTest(live, jpeg: tiny)
        let lenses: PreviewLenses = pane.lenses
        try expect(pane.lens == .look && lenses.activeTasks == 0, "a pane opens on Look with nothing running")
        try expect(
            PreviewLenses.offered == [.look, .compare, .inspect, .quality, .matrix, .rewind],
            "the switcher offers Look, Compare, Inspect, Quality, Matrix and Rewind in that order")

        let two = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "2")), state: 0)
        let chorded = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "2")), state: KeyChord.controlMask)
        let letter = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "a")), state: 0)
        try expect(two.flatMap(PreviewLensKeys.lens(for:)) == .compare, "a plain 2 picks Compare")
        for (digit, lens) in zip("123456", PreviewLenses.offered) {
            let chord = KeyChord.canonical(keyval: UInt32(digit.asciiValue ?? 0), state: 0)
            try expect(chord.flatMap(PreviewLensKeys.lens(for:)) == lens, "the digit \(digit) picks \(lens.rawValue)")
        }
        let seven = KeyChord.canonical(keyval: UInt32(UInt8(ascii: "7")), state: 0)
        try expect(seven.flatMap(PreviewLensKeys.lens(for:)) == nil, "there is no seventh lens")
        let escape = KeyChord.canonical(keyval: Keymap.escape, state: 0)
        try expect(escape.map(PreviewLensKeys.isEscape) == true, "Escape is recognised")
        try expect(escape.flatMap(PreviewLensKeys.lens(for:)) == nil, "and is not a lens")
        try expect(chorded.flatMap(PreviewLensKeys.lens(for:)) == nil, "control and 2 belongs to the window")
        try expect(letter.flatMap(PreviewLensKeys.lens(for:)) == nil, "a letter is not a lens")
        try expect(
            letter.flatMap(PreviewCommand.command(for:)) == .toggleAppearance,
            "the letter commands are untouched")

        let pictures = tailscode_compare_live_pictures()
        try expect(pane.chooseLens(.compare) && pane.lens == .compare, "Compare opens over a live picture")
        let compare = lenses.compareView
        let report = DiffReport(
            width: 12, height: 26, changed: 0.12,
            regions: [
                DiffRegion(x: 3, y: 6, width: 6, height: 13, changed: 0.4),
                DiffRegion(x: 0, y: 0, width: 12, height: 2, changed: 0.2),
            ], sameSize: true)
        compare.present(before: tiny, after: tiny, report: report)
        try expect(tailscode_compare_live_pictures() == pictures + 2, "two shots held, one decode each")
        compare.present(before: tiny, after: tiny, report: report)
        try expect(
            tailscode_compare_live_pictures() == pictures + 2, "a new selection releases the old pair")

        let wide = compare.plan(width: 300, height: 650)
        try expect(wide.count == 12 + 8 && wide[0] == 0 && wide[3] == 2, "the plan holds both outlines")
        try expect(
            near(wide[12], 75) && near(wide[13], 150) && near(wide[14], 150) && near(wide[15], 325),
            "outline 1 maps to its pixels at 300 wide: \(wide.dropFirst(12).prefix(4))")
        let narrow = compare.plan(width: 150, height: 325)
        try expect(
            near(narrow[12], 37.5) && near(narrow[13], 75) && near(narrow[14], 75) && near(narrow[15], 162.5),
            "and at 150 wide: \(narrow.dropFirst(12).prefix(4))")
        try expect(
            near(narrow[16], 0) && near(narrow[17], 0) && near(narrow[18], 150) && near(narrow[19], 25),
            "outline 2 hugs the top edge")
        let boxed = compare.plan(width: 300, height: 300)
        try expect(
            near(boxed[6], 138.46) && near(boxed[4], 80.77) && near(boxed[12], 80.77 + 0.25 * 138.46),
            "a picture that does not fill its box carries its outlines with it")

        compare.setHandle(0.25)
        try expect(near(compare.plan(width: 300, height: 650)[1], 75), "the clip stands at a quarter of the width")
        compare.setHandle(0.6)
        try expect(near(compare.plan(width: 300, height: 650)[1], 180), "and follows the handle to 0.6")
        compare.drag(to: 120, width: 300, height: 650)
        try expect(
            near(compare.handle, 0.4) && near(compare.plan(width: 300, height: 650)[2], 120),
            "a drag to x=120 puts the handle at 0.4")
        compare.drag(to: -50, width: 300, height: 650)
        try expect(compare.handle == 0, "a drag past the left edge stops at the edge")
        compare.drag(to: 9000, width: 300, height: 650)
        try expect(compare.handle == 1, "and past the right")
        _ = compare.drive("mode:side")
        let side = compare.plan(width: 300, height: 300)
        try expect(side[0] == 1 && side[1] == -1 && side[3] == 0 && side.count == 12, "side by side draws no handle or outline")
        _ = compare.drive("mode:slider")

        let before = lenses.activeTasks
        let events = [SessionEvent(seq: 7, at: Date(), kind: "build.done")]
        var arrived = live
        arrived.recent = events
        lenses.stateArrived(arrived)
        try expect(lenses.activeTasks == before + 1, "a build finishing under Compare asks for the list once")
        lenses.stateArrived(arrived)
        try expect(lenses.activeTasks == before + 1, "the same build does not ask again")
        arrived.recent = [SessionEvent(seq: 8, at: Date(), kind: "build.done")]
        lenses.stateArrived(arrived)
        try expect(lenses.activeTasks == before + 1, "a second build replaces the wait rather than adding one")

        _ = pane.chooseLens(.matrix)
        try expect(lenses.activeTasks == 0, "leaving Compare ends its tasks")
        try expect(tailscode_compare_live_pictures() == pictures, "and its pictures")
        let matrix = lenses.matrixView
        let results = PreviewCompareReading.variantSpecs().enumerated().map { index, spec in
            VariantResult(
                label: spec.label, ok: index != 3, bytes: index == 3 ? 0 : tiny.count,
                error: index == 3 ? "no such size" : nil)
        }
        let job = VariantJob(job: "j", state: .done, done: results.count, total: results.count, results: results)
        var fetched: [Int: Data] = [:]
        for index in results.indices where results[index].ok { fetched[index] = tiny }
        matrix.finish(job, pictures: fetched)
        try expect(matrix.cellCount == results.count, "the grid has one cell per result: \(matrix.cellCount)")
        try expect(matrix.failedCount == 1, "and the failed look is counted")
        matrix.enlarge(0)
        try expect(matrix.enlarged == 0, "a thumbnail enlarges in place")
        matrix.enlarge(3)
        try expect(matrix.enlarged == 0, "a look that failed has nothing to enlarge")
        _ = pane.chooseLens(.look)
        try expect(matrix.cellCount == 0 && matrix.enlarged == nil, "leaving Matrix lets go of the grid")

        _ = pane.chooseLens(.rewind)
        let rewind = lenses.rewindView
        let times: [UInt64] = [
            0, 16_000, 32_000, 82_000, 98_000, 498_000, 514_000, 1_000_000, 1_040_000, 1_041_000,
        ]
        try expect(
            PreviewRewindReading.slowFrames(times) == [3, 5],
            "only gaps over 40 ms up to 400 ms are late: \(PreviewRewindReading.slowFrames(times))")
        try expect(PreviewRewindReading.slowFrames([0, 40_000, 441_000]) == [], "40 ms is a frame, 400 ms past it is a pause")
        rewind.load(times.map { PreviewRewindView.Frame(microseconds: $0 + 5_000_000, jpeg: tiny) })
        try expect(rewind.markedSlowFrames == [3, 5], "the scrubber carries a tick for each late frame")
        let ticks = rewind.tickPositions
        try expect(
            ticks.count == 2 && near(ticks[0], 82_000.0 / 1_041_000.0) && near(ticks[1], 498_000.0 / 1_041_000.0),
            "each tick stands at its frame's share of the clip: \(ticks)")
        try expect(rewind.decodedFrames == 1, "only the frame on show is decoded")
        rewind.step(1)
        rewind.step(1)
        try expect(rewind.index == 2 && rewind.decodedFrames == 3, "stepping decodes the frame stepped to")
        rewind.seek(fraction: 0.5)
        try expect(rewind.index == 6, "half way along the clip is the frame taken by then: \(rewind.index)")
        try expect(
            PreviewRewindReading.line(2) == Localized.text("%@ slow frames", "2"), "the line counts them")
        rewind.load([PreviewRewindView.Frame(microseconds: 9_000_000, jpeg: tiny)])
        try expect(
            rewind.frames.count == 1 && rewind.noteText == Localized.text("The screen held still, so there is only one picture"),
            "a still screen is one picture and says so")
        rewind.togglePlay()
        try expect(!rewind.isPlaying, "and has nothing to play")
        rewind.load(times.map { PreviewRewindView.Frame(microseconds: $0 + 5_000_000, jpeg: tiny) })
        rewind.seek(fraction: 0)
        rewind.togglePlay()
        try expect(rewind.isPlaying && lenses.activeTasks == 1, "Play owns exactly one timer")
        rewind.togglePlay()
        try expect(!rewind.isPlaying && lenses.activeTasks == 0, "Pause gives it back")
        rewind.togglePlay()
        _ = pane.chooseLens(.look)
        try expect(!rewind.isPlaying && lenses.activeTasks == 0 && rewind.frames.isEmpty, "leaving Rewind stops and forgets it")
        _ = pane.chooseLens(.rewind)
        rewind.load(times.map { PreviewRewindView.Frame(microseconds: $0, jpeg: tiny) })
        rewind.togglePlay()
        pane.park()
        try expect(
            !rewind.isPlaying && lenses.activeTasks == 0 && !pane.hasTick && rewind.frames.isEmpty,
            "a parked pane owns no lens task, tick or clip")
        pane.shutdown()
        try expect(tailscode_compare_live_pictures() == pictures, "no picture outlives the pane")
        checks += try checkPreviewInspection()
        try expect(Self.criticalsFromSizedPicture(PreviewFixtures.tinyJPEG) == 0, "a picture given its size announces no change of a size that never changes")
        return checks
    }

    nonisolated(unsafe) private static var criticalCount = 0

    /// How many GDK criticals building a picture with an explicit size raises: the paintable says
    /// its size is static, and announcing a change of it afterwards is a warning per picture.
    private static func criticalsFromSizedPicture(_ bytes: Data) -> Int {
        criticalCount = 0
        let handler = g_log_set_handler(
            "Gdk", GLogLevelFlags(rawValue: 8),
            { _, _, _, _ in SelfTest.criticalCount += 1 }, nil)
        defer { g_log_remove_handler("Gdk", handler) }
        let bits = LensDecode.bits(bytes)
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return -1 }
        let picture = tailscode_picture_for_texture_sized(OpaquePointer(raw), 100, 200)
        LensDecode.release(bits)
        if let picture { g_object_ref_sink(UnsafeMutableRawPointer(picture)); g_object_unref(UnsafeMutableRawPointer(picture)) }
        return criticalCount
    }

    private static let inspectTreeJSON = """
        {"id":1,"ok":true,"nodeCount":7,"depth":4,"truncated":false,"root":
         {"id":"0","class":"UIWindow","frame":[0,0,400,800],"alpha":1,"interactive":true,"children":[
          {"id":"0.0","class":"UIView","frame":[0,0,400,800],"alpha":1,"interactive":true,"background":"#F2F2F7","children":[
            {"id":"0.0.0","class":"SaveButton","frame":[40,400,200,80],"alpha":1,"interactive":true,"text":"Save",
             "background":"#3A6DF0","controlTargets":["saveTapped"],"font":{"name":"SFPro-Bold","size":16},
             "accessibility":{"label":"Save","isElement":true},"children":[
              {"id":"0.0.0.0","class":"UIButtonLabel","frame":[100,420,40,20],"alpha":1,"interactive":false,"text":"Save","children":[]}]},
            {"id":"0.0.1","class":"UILabel","frame":[40,100,300,40],"alpha":1,"interactive":false,"text":"Photo Notes","children":[]},
            {"id":"0.0.2","class":"_UITouchPassthroughView","frame":[0,0,400,800],"alpha":1,"interactive":true,"children":[]}]}]}}
        """
    private static let inspectHelloJSON = #"{"app":"PhotoNotes","window":{"width":400,"height":800},"scale":2}"#
    private static let inspectAuditJSON = """
        {"findings":[
         {"kind":"truncation","severity":"warn","nodeId":"0.0.1","class":"UILabel","text":"Photo Notes","message":"m"},
         {"kind":"tapTarget","severity":"fail","nodeId":"0.0.0","class":"SaveButton","message":"m","measured":[76,30],"required":[44,44]}],
         "trustedSystemColors":0}
        """

    /// Inspect and Quality over a hand-built screen: where the outline lands at two picture sizes,
    /// what a press pins and the breadcrumb that walks back up, what is sent to the agent, how the
    /// audit is ordered and offered, and that leaving either lens or parking the pane lets go.
    static func checkPreviewInspection() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("preview: inspect: \(label)") }
            checks += 1
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.01 }
        let decoder = JSONDecoder()
        let tree = try decoder.decode(InspectTree.self, from: Data(inspectTreeJSON.utf8))
        let hello = try decoder.decode(InspectHello.self, from: Data(inspectHelloJSON.utf8))
        let audit = try decoder.decode(InspectAudit.self, from: Data(inspectAuditJSON.utf8))
        guard let live = PreviewFixtures.state("live") else { throw SelfTestFailure("preview: no live fixture") }
        let pane = PreviewPane(
            target: PreviewTarget(host: "mac.local", project: PreviewFixtures.project), runs: false)
        pane.applyForTest(live, jpeg: PreviewFixtures.tinyJPEG)
        let sent = SentWords()
        pane.onAskAgent = { words in sent.add(words) }
        let lenses: PreviewLenses = pane.lenses
        let model = lenses.model

        try expect(
            lenses.chipWords == PreviewLenses.offered.map(\.title), "six chips carry their words in a wide pane")
        lenses.fit(width: 380)
        try expect(lenses.isStacked && lenses.showsGlyphs, "a narrow pane stacks the panel and keeps the chips to glyphs")
        try expect(
            lenses.chipWords.allSatisfy { $0.count == 1 } && Set(lenses.chipWords).count == 6,
            "each glyph is one distinct mark: \(lenses.chipWords)")
        lenses.fit(width: 540)
        try expect(lenses.isStacked && !lenses.showsGlyphs, "a middling pane stacks the panel but has room for words")
        lenses.fit(width: 1100)
        try expect(!lenses.isStacked && !lenses.showsGlyphs, "a wide pane puts the panel beside the picture")

        try expect(pane.chooseLens(.inspect) && pane.lens == .inspect, "Inspect opens over a live picture")
        try expect(lenses.inspectView.messageText == PreviewLensFailure.unreachable, "with no host it says the Mac is not answering")
        try expect(lenses.activeTasks == 0, "and starts nothing it cannot finish")
        model.adopt(hello: hello, tree: tree)
        try expect(lenses.inspectView.messageText == Localized.text("Point at something on the screen. Press to keep it selected."), "a read screen invites a point")

        model.hover(fractionX: 0.2, fractionY: 0.55)
        try expect(model.hovered?.id == "0.0.0", "hovering the button finds the button, not the layer over the screen")
        try expect(lenses.inspectView.headlineText.contains("“Save”"), "the panel names what is under the pointer")
        let small = model.plan(width: 200, height: 400)
        try expect(
            small.hover.count == 1 && near(small.hover[0][0], 20) && near(small.hover[0][1], 200)
                && near(small.hover[0][2], 100) && near(small.hover[0][3], 40),
            "the outline stands on the button at 200 wide: \(small.hover)")
        let large = model.plan(width: 600, height: 1200)
        try expect(
            near(large.hover[0][0], 60) && near(large.hover[0][1], 600) && near(large.hover[0][2], 300)
                && near(large.hover[0][3], 120),
            "and at 600 wide it has moved with the picture: \(large.hover)")
        model.leave()
        try expect(model.plan(width: 200, height: 400).hover.isEmpty, "leaving the picture takes the outline away")

        model.press(fractionX: 0.2, fractionY: 0.55)
        try expect(model.selected?.id == "0.0.0" && model.trail.count == 3, "pressing pins the view with its parents")
        try expect(model.plan(width: 200, height: 400).pinned.count == 1, "the pinned view is outlined")
        try expect(lenses.inspectView.crumbCount == 3, "the breadcrumb has one step per level: \(lenses.inspectView.crumbCount)")
        try expect(lenses.inspectView.rowCount >= 5, "the panel lists the view's facts: \(lenses.inspectView.rowCount)")
        try expect(lenses.inspectView.canSend, "a pinned view can be spoken about")
        model.select(depth: 1)
        try expect(model.selected?.id == "0.0" && lenses.inspectView.crumbCount == 2, "a click on a parent selects the parent")
        model.press(fractionX: 0.2, fractionY: 0.55)
        try expect(model.sentence(saying: "   ") == nil, "nothing typed sends nothing")
        guard let said = model.sentence(saying: "make this bigger") else { throw SelfTestFailure("preview: inspect: no sentence for a pinned view") }
        try expect(said.contains("PhotoNotes") && said.contains("“Save”") && said.hasSuffix("make this bigger"), "the words follow the view they are about")
        lenses.inspectView.type("make this bigger")
        lenses.inspectView.submit()
        try expect(sent.count == 1 && sent.last?.hasSuffix("make this bigger") == true, "Send hands the words to the agent")
        try expect(lenses.inspectView.typedWords.isEmpty && model.selected?.id == "0.0.0", "sending clears the line and selects nothing else")
        try expect(pane.escape() && model.selected == nil, "Escape lets go of the selection")
        try expect(!pane.escape(), "and has nothing to give back the second time")
        model.press(fractionX: 0.9, fractionY: 0.05)
        try expect(model.selected?.id == "0.0", "a press on bare screen pins the screen's own background, not the layers over it")

        try expect(pane.chooseLens(.quality) && pane.lens == .quality, "Quality opens")
        try expect(!lenses.qualityView.offersFix, "and offers nothing before it has read")
        model.adopt(audit: audit)
        let quality = lenses.qualityView
        try expect(quality.findings.map(\.kind) == ["tapTarget", "truncation"], "failures come before warnings")
        try expect(quality.countText == "2 need attention", "the count line is Core's: \(quality.countText)")
        try expect(quality.offersFix, "a failing audit offers Fix these")
        quality.choose(findingID: quality.findings[0].id)
        try expect(model.selected?.id == "0.0.0", "choosing a finding pins its view for Inspect")
        try expect(model.plan(width: 200, height: 400).marked.count == 1, "and outlines it on the picture")
        quality.fix()
        try expect(sent.count == 2 && sent.last?.contains("Hard to press") == true && sent.last?.contains("Words cut off") == true, "Fix these asks the agent with every finding")
        let emptyAudit = try decoder.decode(InspectAudit.self, from: Data(#"{"findings":[],"trustedSystemColors":0}"#.utf8))
        model.adopt(audit: emptyAudit)
        try expect(quality.countText.hasSuffix(Localized.text("Nothing needs attention on this screen")), "an empty audit says so calmly")
        try expect(!quality.offersFix, "and offers nothing to fix")
        let warnOnly = try decoder.decode(
            InspectAudit.self,
            from: Data(#"{"findings":[{"kind":"truncation","severity":"warn","nodeId":"0.0.1","class":"UILabel","text":"Photo Notes","message":"m"}]}"#.utf8))
        model.adopt(audit: warnOnly)
        try expect(!quality.offersFix, "warnings alone do not offer the fix")

        try expect(pane.chooseLens(.look), "back to Look")
        try expect(model.tree == nil && model.audit == nil && model.trail.isEmpty, "leaving the lenses lets go of the screen's views")
        try expect(model.plan(width: 200, height: 400).pinned.isEmpty && model.plan(width: 200, height: 400).marked.isEmpty, "and every outline")
        _ = pane.chooseLens(.inspect)
        model.adopt(hello: hello, tree: tree)
        pane.park()
        try expect(model.tree == nil && lenses.activeTasks == 0, "a parked pane owns neither the tree nor a task")
        pane.shutdown()
        return checks
    }

    private static func fixture(_ name: String) throws -> PreviewState {
        guard let state = PreviewFixtures.state(name) else {
            throw SelfTestFailure("preview: no fixture named \(name)")
        }
        return state
    }
}

/// The words a pane handed to the agent, collected from whichever thread asked.
private final class SentWords: @unchecked Sendable {
    private let lock = NSLock()
    private var words: [String] = []

    func add(_ text: String) {
        lock.lock()
        words.append(text)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return words.count
    }

    var last: String? {
        lock.lock()
        defer { lock.unlock() }
        return words.last
    }
}
