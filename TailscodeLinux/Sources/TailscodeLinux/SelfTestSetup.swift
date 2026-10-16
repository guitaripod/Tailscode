import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

private struct SelfTestReader: SetupCapabilityReader {
    let capability = "selftest"
    var name: String { "Self test" }
    var setUpLabel: String { "Set up the self test" }
    var readyHeadline: String { "The self test is ready" }
    var readyActionLabel: String { "Carry on" }
    func title(of check: SetupCheck) -> String? { "Step \(check.id)" }
    func line(of check: SetupCheck, locale: Locale) -> String? { "state \(check.state.rawValue)" }
    func fixLabel(of fix: SetupFix) -> String? { "Run \(fix.id)" }
    func jobPhrase(of fixID: String) -> String? { "running the step" }
}

private final class SelfTestSource: SetupSource, @unchecked Sendable {
    let capability = "selftest"
    private let lock = NSLock()
    private var done: Set<String> = []
    private var polls: [String: Int] = [:]
    private(set) var started: [String] = []

    func report(for target: SetupTarget) async -> SetupSourceAnswer {
        lock.withLock {
            let first = SetupCheck(
                id: "one", state: done.contains("one") ? .ok : .todo,
                fix: done.contains("one") ? nil : SetupFix(id: "one", bytes: 2_000_000_000, minutes: 1))
            return .report(SetupReport(capability: "selftest", ready: done.contains("one"), checks: [first]))
        }
    }

    func start(fix: String, for target: SetupTarget) async throws -> SetupJob {
        lock.withLock {
            started.append(fix)
            return SetupJob(id: "j-\(fix)", fix: fix, state: .running, fraction: 0, startedAt: 0)
        }
    }

    func job(id: String, for target: SetupTarget) async throws -> SetupJob {
        lock.withLock {
            polls[id, default: 0] += 1
            let fraction = min(1, Double(polls[id] ?? 0) / 2)
            if fraction >= 1 { done.insert(String(id.dropFirst(2))) }
            return SetupJob(
                id: id, fix: String(id.dropFirst(2)), state: fraction >= 1 ? .succeeded : .running,
                fraction: fraction, bytesDone: Int64(fraction * 2_000_000_000), bytesTotal: 2_000_000_000, startedAt: 0)
        }
    }

    func cancel(job id: String, for target: SetupTarget) async throws {}
}

extension SelfTest {
    /// What the checklist promises on this desk without a machine: every fixture state draws the rows,
    /// the headline and the one button Core wrote, in place when only a number moved; work breathes
    /// and nothing else does, and nothing at all under reduced motion; a button on a window reaches
    /// the desk, follows its job to the end and finishes; the server screen's section shows what is
    /// available and nothing else; and the call control's press opens the checklist.
    static func checkSetup() throws -> Int {
        guard gtk_init_check() != 0 else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("setup: \(label)") }
            checks += 1
        }
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                usleep(4000)
            }
            return done()
        }
        let animations = tailscode_animations_enabled() != 0
        defer { tailscode_set_animations_enabled(animations ? 1 : 0) }

        try checkSetupFixtures(expect)
        try checkSetupMotion(expect, pump)
        try checkSetupWindow(expect, pump)
        try checkSetupCapabilities(expect, pump)
        try checkSetupEntry(expect, pump)
        try checkSetupMedia(expect, pump)
        return checks
    }

    private static func checkSetupFixtures(_ expect: (Bool, String) throws -> Void) throws {
        for name in SetupFixtures.names {
            guard let snapshot = SetupFixtures.snapshot(named: name) else {
                try expect(false, "\(name): the fixture exists")
                continue
            }
            let list = SetupChecklist(snapshot: snapshot)
            let view = SetupChecklistView()
            view.apply(list)
            try expect(view.headlineText == list.headline, "\(name): the headline is Core's")
            try expect(view.rowCount == list.rows.count, "\(name): one card per row")
            try expect(view.primaryVisible == (list.primary != nil), "\(name): the button shows only when Core offers one")
            if let primary = list.primary { try expect(view.primaryLabel == primary.label, "\(name): the button's word is Core's") }
            for row in list.rows {
                try expect(view.rowWidget(row.id) != nil, "\(name): the row \(row.id) is drawn")
            }
        }

        let working = try unwrap(SetupFixtures.snapshot(named: "downloading"))
        let view = SetupChecklistView()
        view.apply(SetupChecklist(snapshot: working))
        let before = view.rowWidget("voice.model")
        try expect(view.jobFraction(of: "voice.model").map { abs($0 - 0.31) < 0.001 } ?? false, "the bar reads the job's fraction")
        var moved = working
        moved.job?.fraction = 0.62
        moved.job?.bytesDone = Int64(Double(VoiceRequirements.modelBytes) * 0.62)
        moved.report?.job = moved.job
        view.apply(SetupChecklist(snapshot: moved))
        try expect(view.rowWidget("voice.model") == before, "a number that moved is written in place, not rebuilt")
        try expect(view.jobFraction(of: "voice.model").map { abs($0 - 0.62) < 0.001 } ?? false, "the bar followed")

        let command = SetupChecklistView()
        command.apply(SetupChecklist(snapshot: try unwrap(SetupFixtures.snapshot(named: "command"))))
        let kept = command.rowWidget("voice.cdi")
        command.apply(SetupChecklist(snapshot: try unwrap(SetupFixtures.snapshot(named: "command"))))
        try expect(command.rowWidget("voice.cdi") == kept, "an unchanged command block is the same widget, so a selection survives")
        let ready = try unwrap(SetupFixtures.snapshot(named: "ready"))
        command.apply(SetupChecklist(snapshot: ready))
        try expect(command.rowWidget("voice.cdi") != kept, "a row whose state changed is redrawn")
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw SelfTestFailure("setup: a fixture was missing") }
        return value
    }

    private static func checkSetupMotion(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        func lowestGlyph(_ name: String, row: String, seconds: Double) throws -> Double {
            SetupWindow.dismiss()
            SetupWindow.present(target: SetupFixtures.snapshot(named: name)!.target, parent: nil, fixture: SetupFixtures.snapshot(named: name))
            guard let view = SetupWindow.current?.viewForHarness else { throw SelfTestFailure("setup: no window") }
            var lowest = 1.0
            _ = pump(seconds) {
                if let value = view.glyphOpacity(of: row) { lowest = min(lowest, value) }
                return false
            }
            SetupWindow.dismiss()
            _ = pump(0.1) { false }
            return lowest
        }
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        let breathing = try lowestGlyph("downloading", row: "voice.model", seconds: 2.4)
        try expect(breathing < 0.9, "work breathes: the glyph dims through its swell (\(breathing))")
        let still = try lowestGlyph("ready", row: "voice.gpu", seconds: 1.0)
        try expect(still == 1, "a settled row holds perfectly still (\(still))")
        let blocker = try lowestGlyph("blocker", row: "voice.engine", seconds: 1.0)
        try expect(blocker == 1, "a row that needs you holds still (\(blocker))")
        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        let reduced = try lowestGlyph("downloading", row: "voice.model", seconds: 1.2)
        try expect(reduced == 1, "reduced motion drops the swell and keeps the glyph (\(reduced))")
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
    }

    private static func checkSetupWindow(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        SetupReading.register(SelfTestReader())
        let source = SelfTestSource()
        let runner = SetupRunner.shared
        let registered = DispatchSemaphore(value: 0)
        Task {
            await runner.desk.register(source: source)
            registered.signal()
        }
        _ = pump(2) { registered.wait(timeout: .now()) == .success }

        let finished = FinishFlag()
        let target = SetupTarget(host: "selftest.invalid", capability: "selftest")
        SetupWindow.present(target: target, parent: nil, onFinish: { finished.raise() })
        guard let window = SetupWindow.current else { throw SelfTestFailure("setup: the window did not open") }
        try expect(
            pump(3) { window.checklist?.primary == .setUp(label: "Set up the self test") },
            "the primary button is the capability's own word: \(window.reading)")
        try expect(window.checklist?.rows.first?.fix?.cost == "1.9 GB, about 1 minute", "the fix says what it costs before it starts")

        window.viewForHarness.onPrimary?(.setUp(label: ""))
        try expect(pump(4) { window.checklist?.status == .working }, "pressing it starts the job: \(window.reading)")
        try expect(pump(4) { window.checklist?.jobRow?.job?.line?.contains("GB") == true }, "the bar reads bytes of the total: \(window.reading)")
        try expect(
            pump(8) { window.checklist?.primary == .finish(label: "Carry on") },
            "the job is followed to its end and the checklist offers to finish: \(window.reading)")
        try expect(window.checklist?.headline == "The self test is ready", "the headline is the capability's own")
        try expect(source.started == ["one"], "the fix was started once")

        window.viewForHarness.onPrimary?(.finish(label: ""))
        try expect(pump(2) { SetupWindow.current == nil }, "finishing closes the window")
        try expect(finished.raised, "finishing runs what the caller wanted next")

        SetupWindow.present(target: target, parent: nil)
        let second = SetupWindow.current
        SetupWindow.present(target: target, parent: nil)
        try expect(SetupWindow.current === second, "a second ask for the same checklist raises the open one")
        SetupWindow.dismiss()
        _ = pump(0.1) { false }
    }

    private static func checkSetupCapabilities(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        let demoHost = DelegateDemo.hosts.sorted().first ?? ""
        let shown = SetupCapabilitiesRows(
            profileURL: URL(string: "http://\(demoHost):4098")!, parent: { nil })
        shown.start()
        try expect(pump(4) { shown.rowCount == 1 }, "a machine that can do voice shows one row: \(shown.summary)")
        try expect(shown.isShown && shown.summary.contains("voice=Needs setup"), "the row carries Core's chip and line: \(shown.summary)")
        shown.stop()

        let silent = SetupCapabilitiesRows(
            profileURL: URL(string: "http://nowhere.selftest.invalid:4098")!, parent: { nil })
        silent.start()
        _ = pump(1.5) { false }
        try expect(silent.rowCount == 0 && !silent.isShown, "a machine that cannot be asked shows no section at all")
        silent.stop()
    }

    private static func checkSetupEntry(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        defer {
            VoiceCallRunner.forcedReach = nil
            VoiceCallRunner.forcedEndpoint = nil
            SetupWindow.dismiss()
        }
        for reach in [VoiceReach.noGateway, .needsSetup, .engineDown(detail: "CUDA out of memory")] {
            let host = CallStubHost(chat: "setup-entry")
            VoiceCallRunner.forcedEndpoint = VoiceEndpoint(host: "setup-entry.selftest.invalid")
            VoiceCallRunner.forcedReach = reach
            let call = PaneCall(host: host)
            call.refresh()
            call.pressEntry()
            _ = pump(0.3) { false }
            try expect(
                SetupWindow.current?.reading.contains("target=voice") == true,
                "\(reach): a press opens the voice checklist instead of toasting a reason")
            try expect(host.notices.isEmpty, "\(reach): and nothing is toasted")
            SetupWindow.dismiss()
            _ = pump(0.1) { false }
            call.shutdown()
        }
    }
}

final class FinishFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var raised: Bool { lock.withLock { value } }
    func raise() { lock.withLock { value = true } }
}
