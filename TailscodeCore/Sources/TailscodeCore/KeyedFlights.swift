import Foundation

/// Lets every caller that asks for the same thing while it is already being fetched wait on the one
/// fetch instead of starting its own.
///
/// Four screens each keep a listing of every server, and a server that has just come back — or an
/// app that has just launched — makes each of them ask each server at once. A listing is hundreds
/// of kilobytes that the bridge folds out of every transcript it holds, so asking sixteen times
/// for what one answer settles costs a bridge seconds and a phone megabytes.
///
/// A flight is joined only while it is in the air: an answer is never reused after it lands, so
/// nothing here can hand back an old list. A caller that has just changed what the answer holds
/// passes `joining: false`, because a fetch begun before its change cannot know about it; its
/// flight then becomes the one later callers join.
public actor KeyedFlights<Key: Hashable & Sendable, Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, Never>
    }

    private var flights: [Key: Flight] = [:]

    public init() {}

    public func run(
        _ key: Key, joining: Bool = true, _ work: @escaping @Sendable () async -> Value
    ) async -> Value {
        if joining, let flight = flights[key] { return await flight.task.value }
        let flight = Flight(id: UUID(), task: Task { await work() })
        flights[key] = flight
        let value = await flight.task.value
        if flights[key]?.id == flight.id { flights[key] = nil }
        return value
    }

    public var inFlight: Int { flights.count }
}
