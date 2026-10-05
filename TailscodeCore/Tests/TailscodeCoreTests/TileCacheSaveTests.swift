import Foundation
import Testing
@testable import TailscodeCore

@Suite("Coalesced session-list save")
struct TileCacheSaveTests {
    @Test("A burst becomes one trailing write of the newest value, off the caller's thread")
    func coalesces() async {
        let writes = Tally<Int>()
        let threads = Tally<Bool>()
        let coalescer = SessionListSaveCoalescer<Int>(delay: 0.05) { value in
            writes.add(value)
            threads.add(Thread.isMainThread)
        }
        for value in 1...50 { coalescer.schedule(value) }
        #expect(writes.count == 0)
        #expect(await eventually { writes.count == 1 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(writes.all == [50])
        #expect(threads.all == [false])
        coalescer.schedule(51)
        #expect(await eventually { writes.count == 2 })
        #expect(writes.all == [50, 51])
    }

    @Test("Flush writes what is pending at once, and nothing when nothing is")
    func flush() async {
        let writes = Tally<Int>()
        let coalescer = SessionListSaveCoalescer<Int>(delay: 60) { writes.add($0) }
        coalescer.flush()
        #expect(writes.count == 0)
        coalescer.schedule(1)
        coalescer.schedule(2)
        #expect(coalescer.isPending)
        coalescer.flush()
        #expect(writes.all == [2])
        #expect(!coalescer.isPending)
        coalescer.flush()
        #expect(writes.all == [2])
    }
}
