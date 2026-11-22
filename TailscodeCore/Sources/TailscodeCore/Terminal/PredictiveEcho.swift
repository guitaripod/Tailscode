import Foundation

/// Characters drawn the moment they are typed, before the shell's echo comes back.
///
/// Over a slow link every key waits a round trip to appear, which on a phone's network is a
/// quarter of a second or more. So a typed character is shown at once after the cursor, and the
/// shell's own echo, matched byte for byte as it arrives, takes its place. A prediction is shown
/// only while the line being typed has proven that it echoes: the first key after Return, after a
/// named key or after anything that did not match waits for its echo like any other, so a
/// password prompt, which echoes nothing, never shows what is typed into it. A guess the shell
/// contradicts, or leaves unanswered for two seconds, is dropped and trust starts over.
struct PredictiveEcho: Sendable {
    struct Guess: Sendable, Equatable {
        var byte: UInt8
        var at: Date
    }

    static let patience: TimeInterval = 2

    private(set) var pending: [Guess] = []
    private(set) var trusted = false

    /// What is shown: the guesses, when the line has earned it.
    var shown: [UInt8] { trusted ? pending.map(\.byte) : [] }

    /// Printable ASCII is guessed one cell per byte; anything else is left to the shell.
    static func guessable(_ text: String) -> [UInt8]? {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return bytes
    }

    mutating func typed(_ text: String, at moment: Date) {
        guard let bytes = Self.guessable(text) else {
            forget()
            return
        }
        pending.append(contentsOf: bytes.map { Guess(byte: $0, at: moment) })
    }

    /// Return, an arrow, a deletion, a paste: what the shell will do is not a guess any more.
    mutating func forget() {
        pending.removeAll()
        trusted = false
    }

    /// The shell's bytes, matched against the guesses from the oldest. An echo that matches
    /// confirms the line; the first byte that does not drops every guess left, and output nobody
    /// typed (a prompt redrawn, a job printing) takes the trust away until the next echo.
    mutating func heard(_ bytes: Data) {
        for byte in bytes {
            guard let first = pending.first else {
                trusted = false
                return
            }
            if first.byte == byte {
                pending.removeFirst()
                trusted = true
            } else {
                forget()
                return
            }
        }
    }

    /// Guesses the shell has left unanswered too long are not going to be answered.
    mutating func expire(at moment: Date) {
        guard let oldest = pending.first, moment.timeIntervalSince(oldest.at) > Self.patience else { return }
        forget()
    }
}
