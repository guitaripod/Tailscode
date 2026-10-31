import Foundation
import Testing

@testable import TailscodeCore

@Suite struct KeyedFlightsTests {
    private actor Counter {
        private(set) var started = 0
        func begin() -> Int {
            started += 1
            return started
        }
    }

    @Test func callersAskingTogetherShareOneFetch() async {
        let flights = KeyedFlights<String, Int>()
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let answers = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await flights.run("arch") {
                        let number = await counter.begin()
                        for await _ in gate.stream { break }
                        return number
                    }
                }
            }
            while await flights.inFlight == 0 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(50))
            gate.continuation.yield()
            var all: [Int] = []
            for await answer in group { all.append(answer) }
            return all
        }
        #expect(await counter.started == 1)
        #expect(Set(answers) == [1])
    }

    @Test func differentKeysAreFetchedSeparately() async {
        let flights = KeyedFlights<String, String>()
        async let arch = flights.run("arch") { "a" }
        async let macbook = flights.run("macbook") { "m" }
        #expect(await [arch, macbook] == ["a", "m"])
    }

    @Test func anAnswerThatHasLandedIsNeverReused() async {
        let flights = KeyedFlights<String, Int>()
        let counter = Counter()
        let first = await flights.run("arch") { await counter.begin() }
        let second = await flights.run("arch") { await counter.begin() }
        #expect(first == 1)
        #expect(second == 2)
        #expect(await flights.inFlight == 0)
    }

    @Test func aCallerThatChangedTheAnswerStartsAFetchOfItsOwn() async {
        let flights = KeyedFlights<String, Int>()
        let counter = Counter()
        let gate = AsyncStream<Void>.makeStream()
        let slow = Task {
            await flights.run("arch") {
                let number = await counter.begin()
                for await _ in gate.stream { break }
                return number
            }
        }
        while await counter.started == 0 { await Task.yield() }
        let fresh = await flights.run("arch", joining: false) { await counter.begin() }
        gate.continuation.yield()
        #expect(fresh == 2)
        #expect(await slow.value == 1)
        #expect(await flights.inFlight == 0)
    }

    @Test func aFlightThatFinishedAfterBeingReplacedLeavesTheNewerOneJoinable() async {
        let flights = KeyedFlights<String, Int>()
        let counter = Counter()
        let oldGate = AsyncStream<Void>.makeStream()
        let newGate = AsyncStream<Void>.makeStream()
        let old = Task {
            await flights.run("arch") {
                _ = await counter.begin()
                for await _ in oldGate.stream { break }
                return 1
            }
        }
        while await counter.started == 0 { await Task.yield() }
        let replacement = Task {
            await flights.run("arch", joining: false) {
                _ = await counter.begin()
                for await _ in newGate.stream { break }
                return 2
            }
        }
        while await counter.started < 2 { await Task.yield() }
        oldGate.continuation.yield()
        #expect(await old.value == 1)
        #expect(await flights.inFlight == 1)
        let joiner = Task { await flights.run("arch") { 3 } }
        try? await Task.sleep(for: .milliseconds(50))
        newGate.continuation.yield()
        #expect(await joiner.value == 2)
        #expect(await replacement.value == 2)
    }
}
