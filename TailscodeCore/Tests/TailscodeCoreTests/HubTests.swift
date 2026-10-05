import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing
@testable import TailscodeCore

@Suite("Conversation hub")
struct HubTests {
    private final class Scheduled: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [@Sendable () -> Void] = []

        var scheduler: ConversationHub.Scheduler {
            { [self] _, work in
                lock.lock()
                jobs.append(work)
                lock.unlock()
            }
        }

        func runAll() {
            lock.lock()
            let due = jobs
            jobs = []
            lock.unlock()
            for job in due { job() }
        }

        var pending: Int {
            lock.lock()
            defer { lock.unlock() }
            return jobs.count
        }
    }

    private final class Edges: LiveEdges, @unchecked Sendable {
        let observed = Tally<UInt64>()
        private let lock = NSLock()
        private var needs = false
        private var count: UInt64 = 0

        func observe(_ key: LiveKey, _ state: ConversationState) {
            lock.lock()
            count += 1
            let value = count
            lock.unlock()
            observed.add(value)
        }

        func needsStream(_ key: LiveKey) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return needs
        }

        func set(needs value: Bool) {
            lock.lock()
            needs = value
            lock.unlock()
        }
    }

    private final class Opener: @unchecked Sendable {
        let opens = Tally<LiveKey>()
        private let lock = NSLock()
        private var made: [AgentConversation] = []

        func open(_ key: LiveKey) -> AgentConversation {
            opens.add(key)
            let script = (0..<6).map { index in
                MockScriptStep(
                    .messageUpserted(
                        ChatMessage(
                            id: "m\(index)", role: .assistant, agentType: .claudeCode,
                            parts: [MessagePart(id: "p\(index)", kind: .text("word \(index)"))],
                            createdAt: Date(timeIntervalSince1970: Double(index))),
                        replaceParts: true),
                    delay: .milliseconds(5))
            }
            let backend = MockBackend(agentType: .claudeCode, script: script, interactive: true)
            let conversation = AgentConversation(backend: backend, sessionID: key.sessionID)
            lock.lock()
            made.append(conversation)
            lock.unlock()
            return conversation
        }

        var last: AgentConversation? {
            lock.lock()
            defer { lock.unlock() }
            return made.last
        }
    }

    private struct World {
        let clock = ManualClock()
        let scheduled = Scheduled()
        let edges = Edges()
        let opener = Opener()
        let hub: ConversationHub

        init() {
            let opener = self.opener
            hub = ConversationHub(
                open: { key in opener.open(key) }, clock: clock, edges: edges,
                schedule: scheduled.scheduler)
        }
    }

    private let key = LiveKey(profileID: "p", sessionID: "s")

    @Test("Two leases on one key share one open and one stream; edges fire once per state")
    func sharedOpen() async {
        let world = World()
        let dirtyA = Tally<Int>()
        let dirtyB = Tally<Int>()
        let a = world.hub.lease(key, interest: .full) { dirtyA.add(1) }
        let b = world.hub.lease(key, interest: .glance) { dirtyB.add(1) }
        #expect(await eventually { world.hub.latest(key)?.state.messages.count == 6 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(world.opener.opens.count == 1)
        #expect(world.hub.leaseCount(key) == 2)
        let sequence = world.hub.latest(key)?.sequence ?? 0
        #expect(world.edges.observed.count == Int(sequence))
        let frameA = a.take()
        let frameB = b.take()
        #expect(frameA?.sequence == sequence)
        #expect(frameB?.sequence == sequence)
        #expect(a.take() == nil)
        #expect(dirtyA.count >= 1)
        #expect(dirtyA.count <= Int(sequence))
        a.cancel()
        b.cancel()
    }

    @Test("A late lease is handed the newest state at once")
    func lateLease() async {
        let world = World()
        let first = world.hub.lease(key, interest: .full) {}
        #expect(await eventually { world.hub.latest(key)?.state.messages.count == 6 })
        let dirty = Tally<Int>()
        let late = world.hub.lease(key, interest: .glance) { dirty.add(1) }
        #expect(dirty.count == 1)
        #expect(late.take()?.state.messages.count == 6)
        #expect(world.opener.opens.count == 1)
        first.cancel()
        late.cancel()
    }

    @Test("The last lease out keeps the stream through the grace, then stops the Kit's run loop")
    func graceThenStop() async {
        let world = World()
        let lease = world.hub.lease(key, interest: .full) {}
        #expect(await eventually { world.hub.latest(key) != nil })
        let conversation = world.opener.last
        #expect(await conversation?.hasObservers == true)
        lease.cancel()
        lease.cancel()
        #expect(world.hub.isStreaming(key))
        #expect(world.scheduled.pending == 1)
        world.clock.advance(4.9)
        world.scheduled.runAll()
        #expect(world.hub.isStreaming(key))
        #expect(world.scheduled.pending == 1)
        world.clock.advance(0.2)
        world.scheduled.runAll()
        #expect(!world.hub.isStreaming(key))
        #expect(world.hub.keys.isEmpty)
        var stopped = false
        for _ in 0..<500 {
            if await conversation?.hasObservers == false {
                stopped = true
                break
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(stopped)
    }

    @Test("A lease taken inside the grace keeps the stream without redialling")
    func rebalanceInsideGrace() async {
        let world = World()
        let first = world.hub.lease(key, interest: .full) {}
        #expect(await eventually { world.hub.latest(key) != nil })
        first.cancel()
        let second = world.hub.lease(key, interest: .glance) {}
        world.clock.advance(10)
        world.scheduled.runAll()
        #expect(world.hub.isStreaming(key))
        #expect(world.opener.opens.count == 1)
        second.cancel()
    }

    @Test("Interest decides the stream: watching keeps it only while the edges need it")
    func interestChanges() async {
        let world = World()
        let lease = world.hub.lease(key, interest: .watching) {}
        #expect(!world.hub.isStreaming(key))
        lease.set(interest: .glance)
        #expect(world.hub.isStreaming(key))
        #expect(await eventually { world.hub.latest(key) != nil })
        lease.set(interest: .watching)
        world.clock.advance(6)
        world.scheduled.runAll()
        #expect(!world.hub.isStreaming(key))
        #expect(world.hub.leaseCount(key) == 1)
        world.edges.set(needs: true)
        world.hub.reevaluate(key)
        #expect(world.hub.isStreaming(key))
        #expect(world.opener.opens.count == 1)
        lease.set(interest: .full)
        lease.set(interest: .watching)
        world.clock.advance(6)
        world.scheduled.runAll()
        #expect(world.hub.isStreaming(key))
        lease.cancel()
        world.clock.advance(6)
        world.scheduled.runAll()
        #expect(!world.hub.isStreaming(key))
    }

    @Test("Separate keys get separate conversations")
    func separateKeys() async {
        let world = World()
        let a = world.hub.lease(key, interest: .full) {}
        let b = world.hub.lease(LiveKey(profileID: "p", sessionID: "t"), interest: .full) {}
        #expect(await eventually { world.opener.opens.count == 2 })
        #expect(Set(world.hub.keys).count == 2)
        a.cancel()
        b.cancel()
    }

    @Test("A released lease that is dropped without cancel releases itself")
    func deinitReleases() async {
        let world = World()
        do {
            let lease = world.hub.lease(key, interest: .full) {}
            #expect(world.hub.leaseCount(key) == 1)
            _ = lease
        }
        #expect(world.hub.leaseCount(key) == 0)
    }

    @Test("The shared conversation is reachable through a lease")
    func conversationAccess() async {
        let world = World()
        let lease = world.hub.lease(key, interest: .watching) {}
        let conversation = await lease.conversation()
        #expect(conversation != nil)
        #expect(conversation === world.opener.last)
        #expect(await world.hub.conversation(for: LiveKey(profileID: "x", sessionID: "y")) == nil)
        lease.cancel()
    }

    @Test("Concurrent leases and cancels leave nothing behind")
    func concurrentLeases() async {
        let world = World()
        let hub = world.hub
        let key = self.key
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let lease = hub.lease(key, interest: index % 2 == 0 ? .full : .watching) {}
            if index % 3 == 0 { lease.set(interest: .glance) }
            _ = lease.take()
            lease.cancel()
        }
        #expect(hub.leaseCount(key) == 0)
        world.clock.advance(6)
        world.scheduled.runAll()
        world.scheduled.runAll()
        #expect(!hub.isStreaming(key))
    }

    @Test("A stream that finishes on its own is dialled again after a backoff while a lease holds it")
    func redialAfterFinish() async {
        let clock = ManualClock()
        let scheduled = Scheduled()
        let opens = Tally<LiveKey>()
        let hub = ConversationHub(
            open: { key in
                opens.add(key)
                let backend = MockBackend(
                    agentType: .claudeCode,
                    script: [
                        MockScriptStep(
                            .messageUpserted(
                                ChatMessage(
                                    id: "m", role: .assistant, agentType: .claudeCode,
                                    parts: [MessagePart(id: "p", kind: .text("word"))],
                                    createdAt: Date(timeIntervalSince1970: 1)),
                                replaceParts: true),
                            delay: .milliseconds(5))
                    ])
                return AgentConversation(
                    backend: backend, sessionID: key.sessionID,
                    policy: ConnectionPolicy(maxReconnectAttempts: 0))
            }, clock: clock, edges: Edges(), schedule: scheduled.scheduler)
        let lease = hub.lease(key, interest: .full) {}
        #expect(await eventually { !hub.isStreaming(key) && scheduled.pending == 1 })
        scheduled.runAll()
        #expect(hub.isStreaming(key))
        #expect(opens.count == 1)
        lease.cancel()
        #expect(await eventually { !hub.isStreaming(key) || scheduled.pending > 0 })
        clock.advance(60)
        for _ in 0..<4 { scheduled.runAll() }
        #expect(await eventually { hub.keys.isEmpty })
    }

    @Test("A finished stream with no lease left is dropped rather than redialled")
    func noRedialWithoutLease() async {
        let world = World()
        let lease = world.hub.lease(key, interest: .full) {}
        #expect(await eventually { world.hub.latest(key) != nil })
        lease.cancel()
        world.clock.advance(6)
        world.scheduled.runAll()
        #expect(world.hub.keys.isEmpty)
        #expect(world.scheduled.pending == 0)
    }
}
