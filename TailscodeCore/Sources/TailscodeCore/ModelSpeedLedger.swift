import Foundation

/// What each model has actually run at on this device, remembered across sessions.
///
/// A single turn's speed answers "was that slow"; only a memory of many answers "is it always".
/// The ledger keeps, per model, how many settled turns it has watched, the tokens they wrote and
/// the seconds they took, and quotes the quotient — the same arithmetic as a turn's own rate,
/// pooled. Provider speeds drift, so the memory decays: once a model has contributed 256 turns,
/// every aggregate is halved before the next one lands, which turns the mean into a
/// recency-weighted average without keeping a single sample around.
///
/// It is device-local deliberately. Every figure that feeds it is the server's own, but *which*
/// turns fed it depends on which conversations this device happened to render, so two devices may
/// legitimately remember different averages — the ledger says "here", never "everywhere". A turn
/// feeds it at most once, however many times the transcript is rebuilt.
public final class ModelSpeedLedger: @unchecked Sendable {
    public static let shared = ModelSpeedLedger()

    public struct Reading: Sendable, Hashable {
        public let tokensPerSecond: Double
        public let turns: Int
    }

    struct Account: Codable {
        var samples: Int = 0
        var tokens: Double = 0
        var seconds: Double = 0
    }

    private struct Book: Codable {
        var accounts: [String: Account] = [:]
        var recorded: [String] = []
    }

    static let defaultsKey = "tailscode.modelSpeed"
    /// The point past which the memory starts forgetting, taken from oh-my-pi's model_perf table:
    /// halving at 256 keeps roughly the last few hundred turns dominant however long the ledger
    /// lives.
    static let decayThreshold = 256
    /// How many turn ids are kept to keep a rebuilt transcript from feeding the same turn twice.
    /// A device rerenders the conversations it has open, not its whole history, so a short ring
    /// is enough.
    static let recordedRing = 512
    /// Below this many turns the ledger stays quiet: two readings of one model are an anecdote,
    /// not an average.
    static let quorum = 3

    private let lock = NSLock()
    private var book: Book
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode(Book.self, from: data)
        {
            book = decoded
        } else {
            book = Book()
        }
    }

    /// Feeds one settled turn's reading. Idempotent per turn id, so the render path can call it
    /// every time it builds the strip and the ledger still counts each answer once.
    public func record(turnID: String, model: String, tokens: Int, seconds: TimeInterval) {
        guard tokens > 0, seconds > 0, !model.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !book.recorded.contains(turnID) else { return }
        book.recorded.append(turnID)
        if book.recorded.count > Self.recordedRing {
            book.recorded.removeFirst(book.recorded.count - Self.recordedRing)
        }
        var account = book.accounts[model] ?? Account()
        if account.samples >= Self.decayThreshold {
            account.samples /= 2
            account.tokens /= 2
            account.seconds /= 2
        }
        account.samples += 1
        account.tokens += Double(tokens)
        account.seconds += seconds
        book.accounts[model] = account
        if let data = try? JSONEncoder().encode(book) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// What this model has averaged here, or nil while the ledger has too little to say.
    public func reading(model: String?) -> Reading? {
        guard let model, !model.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let account = book.accounts[model], account.samples >= Self.quorum,
            account.seconds > 0
        else { return nil }
        return Reading(
            tokensPerSecond: account.tokens / account.seconds, turns: account.samples)
    }

    /// The sentence a speed figure's tooltip appends, or nil while there is nothing to compare to.
    public func sentence(model: String?) -> String? {
        guard let reading = reading(model: model) else { return nil }
        return Localized.text(
            "This model has averaged %@ tok/s here over %d turns.",
            ResponseStats.rate(reading.tokensPerSecond), reading.turns)
    }
}
