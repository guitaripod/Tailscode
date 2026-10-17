import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Sidebar render plan", .serialized)
struct SidebarRenderPlanTests {
    private func entry(
        _ id: String, profile: String = "one", updated: TimeInterval = 0, title: String = "chat",
        active: Bool? = nil
    ) -> SessionEntry {
        let stamp = Date(timeIntervalSince1970: updated)
        return SessionEntry(
            profileID: profile, profileName: profile, host: profile, backendType: .claudeCode,
            session: AgentSession(
                id: id, agentType: .claudeCode, title: title, directory: "/tmp/\(profile)",
                createdAt: stamp, updatedAt: stamp, isActive: active))
    }

    @Test("A burst of requests costs the run that went first and the one that closes it")
    func burstRunsTwice() {
        var coalescer = RenderCoalescer()
        var runs = 0
        var timers: [(Int, TimeInterval)] = []
        var clock: TimeInterval = 100
        for step in 0..<50 {
            clock += 0.001 * Double(step % 3)
            switch coalescer.request(at: clock, interval: 0.1) {
            case .runNow: runs += 1
            case .wait(let delay, let token): timers.append((token, delay))
            case .covered: break
            }
        }
        #expect(runs == 1)
        #expect(timers.count == 1, "one trailing run is promised for the whole burst")
        let (token, delay) = timers[0]
        clock += delay
        let owed = coalescer.fire(token: token, at: clock)
        #expect(owed)
        runs += 1
        #expect(runs == 2)
        #expect(!coalescer.isWaiting)
        let again = coalescer.fire(token: token, at: clock)
        #expect(!again, "a spent token does nothing")
    }

    @Test("The last request is never dropped, and quiet gaps run at once")
    func lastRequestRuns() {
        var coalescer = RenderCoalescer()
        let first = coalescer.request(at: 10, interval: 0.1)
        #expect(first == .runNow)
        guard case .wait(let delay, let token) = coalescer.request(at: 10.02, interval: 0.1) else {
            Issue.record("a request inside the interval waits")
            return
        }
        #expect(abs(delay - 0.08) < 0.0001)
        let covered = coalescer.request(at: 10.05, interval: 0.1)
        #expect(covered == .covered)
        let owed = coalescer.fire(token: token, at: 10.1)
        #expect(owed)
        let quiet = coalescer.request(at: 11, interval: 0.1)
        #expect(quiet == .runNow)
    }

    @Test("A flush satisfies the promise it overtakes")
    func flushSpendsThePromise() {
        var coalescer = RenderCoalescer()
        _ = coalescer.request(at: 5, interval: 0.1)
        guard case .wait(_, let token) = coalescer.request(at: 5.01, interval: 0.1) else {
            Issue.record("expected a promise")
            return
        }
        coalescer.flush(at: 5.02)
        let late = coalescer.fire(token: token, at: 5.1)
        #expect(!late, "the timer finds nothing owed")
        guard case .wait(_, let next) = coalescer.request(at: 5.03, interval: 0.1) else {
            Issue.record("the flush starts a new interval")
            return
        }
        #expect(next != token)
    }

    @Test("The interval stretches with the shed level and a hidden window draws slowly")
    func cadenceStretches() {
        #expect(SidebarCadence.interval(at: .calm, visible: true) == 0.1)
        #expect(SidebarCadence.interval(at: .loaded, visible: true) == 0.25)
        #expect(SidebarCadence.interval(at: .strained, visible: true) == 0.5)
        #expect(SidebarCadence.interval(at: .critical, visible: true) == 1)
        #expect(SidebarCadence.interval(at: .calm, visible: false) == 1)
    }

    @Test("A running step that says nothing is the row without a step")
    func emptyStepReadsAsNone() {
        #expect(SessionPresence.running("").sidebarReading == SessionPresence.running(nil))
        #expect(SessionPresence.running("Bash").sidebarReading == SessionPresence.running("Bash"))
        #expect(SessionPresence.failed.sidebarReading == SessionPresence.failed)
    }

    @Test("A model is reused until something it was built from moves")
    func cacheRebuildsOnlyWhatMoved() {
        var cache = SessionRowModelCache()
        let a = entry("a", updated: 1_000)
        let b = entry("b", updated: 900)
        let now = Date(timeIntervalSince1970: 100_000)
        func pass(_ list: [SessionEntry], presence: SessionPresence = .unobserved, pinned: Set<String> = []) -> [SessionRowModel] {
            cache.beginPass()
            let rows = list.map {
                cache.model(
                    for: $0, unreachable: false, unread: false, saved: false,
                    pinned: pinned.contains($0.session.id), presence: presence, observedAt: nil,
                    now: now)
            }
            cache.sweep()
            return rows
        }
        _ = pass([a, b])
        #expect(cache.misses == 2)
        _ = cache.takeRebuilt()
        let again = pass([a, b])
        #expect(cache.hits == 2 && cache.misses == 0)
        let untouched = cache.takeRebuilt()
        #expect(untouched.isEmpty)
        #expect(again[0] == SessionRowModel(entry: a, unreachable: false, unread: false, saved: false, pinned: false, now: now))

        let renamed = entry("a", updated: 1_000, title: "renamed")
        let moved = pass([renamed, b])
        #expect(cache.misses == 1 && cache.hits == 1)
        #expect(moved[0].title == "renamed")
        let changed = cache.takeRebuilt()
        #expect(changed == [SessionPinStore.key("one", "a")])

        _ = pass([renamed, b], pinned: ["b"])
        #expect(cache.misses == 1, "a pin is an input")
        let running = pass([renamed, b], presence: .running("Bash"))
        #expect(cache.misses == 2)
        #expect(running[0].snippet == "Bash")
        _ = pass([renamed, b], presence: .running("Bash"))
        #expect(cache.hits == 2)

        _ = pass([b])
        _ = pass([renamed, b])
        #expect(cache.misses == 1, "a chat that left the list was forgotten")
    }

    @Test("An age that ticks over is a change; a stale cache never freezes it")
    func ageIsAnInput() {
        var cache = SessionRowModelCache()
        let a = entry("a", updated: 1_000)
        func model(at seconds: TimeInterval) -> SessionRowModel {
            cache.beginPass()
            return cache.model(
                for: a, unreachable: false, unread: false, saved: false, pinned: false,
                presence: .unobserved, observedAt: nil,
                now: Date(timeIntervalSince1970: seconds))
        }
        #expect(model(at: 1_030).age == "30s")
        #expect(model(at: 1_031).age == "31s")
        #expect(model(at: 1_031).age == "31s")
        #expect(cache.hits == 1)
    }

    @Test("Placing one change gives what filtering, appending and sorting would")
    func upsertMatchesFullSort() {
        var generator = SystemRandomNumberGenerator()
        var listing = (0..<40).map { entry("s\($0)", updated: Double(1_000 - $0 * 10)) }
        listing.sort { $0.session.updatedAt > $1.session.updatedAt }
        for round in 0..<400 {
            let id = "s\(Int.random(in: 0..<45, using: &generator))"
            let bucket = Int.random(in: 0..<30, using: &generator)
            let change = entry(id, updated: Double(1_000 - bucket * 10), title: "r\(round)")
            var expected = listing.filter { !($0.profileID == change.profileID && $0.session.id == id) }
            expected.append(change)
            expected.sort { $0.session.updatedAt > $1.session.updatedAt }
            SessionListOrder.upsert(change, into: &listing)
            #expect(
                listing.map { $0.session.id + $0.session.title }
                    == expected.map { $0.session.id + $0.session.title })
        }
        #expect(SessionListOrder.isNewestFirst(listing))
        SessionListOrder.remove(profileID: "one", sessionID: "s1", from: &listing)
        #expect(!listing.contains { $0.session.id == "s1" })
    }

    @Test("The pin snapshot is one read and keeps first places")
    func pinSnapshot() {
        let key = SessionPinStore.storageKey
        let defaults = UserDefaults.standard
        let before = defaults.stringArray(forKey: key)
        defer { defaults.set(before, forKey: key) }
        defaults.set(["p/a", "p/b", "p/a"], forKey: key)
        #expect(SessionPinStore.snapshot() == ["p/a", "p/b"])
        #expect(SessionPinStore.ranks() == ["p/a": 0, "p/b": 1])
        #expect(SessionPinStore.rank(profileID: "p", sessionID: "a") == 0)
    }

    @Test("Sections order the pins as the store does, from one read of the ranks")
    func pinnedSectionOrder() {
        let key = SessionPinStore.storageKey
        let defaults = UserDefaults.standard
        let before = defaults.stringArray(forKey: key)
        defer { defaults.set(before, forKey: key) }
        defaults.set(["one/c", "one/a", "one/b"], forKey: key)
        let rows = ["a", "b", "c", "d"].map {
            SessionRowModel(
                entry: entry($0, updated: 10), unreachable: false, unread: false, saved: false,
                pinned: $0 != "d")
        }
        let sections = groupIntoSections(rows)
        #expect(sections.map(\.0) == [.pinned, .recent])
        #expect(sections[0].1.map { $0.entry.session.id } == ["c", "a", "b"])
    }

    @Test("Pass cost over a long listing", .tags(.measured))
    func longListingIsCheapToReuse() {
        let listing = (0..<1_290).map { entry("s\($0)", updated: Double(100_000 - $0)) }
        var cache = SessionRowModelCache()
        let now = Date(timeIntervalSince1970: 200_000)
        func pass() -> TimeInterval {
            let start = ProcessInfo.processInfo.systemUptime
            cache.beginPass()
            for item in listing {
                _ = cache.model(
                    for: item, unreachable: false, unread: false, saved: false, pinned: false,
                    presence: .unobserved, observedAt: nil, now: now)
            }
            cache.sweep()
            return ProcessInfo.processInfo.systemUptime - start
        }
        let cold = pass()
        let warm = pass()
        #expect(cache.hits == 1_290)
        print("sidebar model pass over 1290 chats: cold \(cold * 1000) ms, warm \(warm * 1000) ms")
    }
}

extension Tag {
    @Tag static var measured: Self
}
