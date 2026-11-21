import MidgarCore
import UIKit

/// What a tap on a chat cost, moment by moment, in milliseconds since the press that asked for it:
/// when its screen was made, its view built and laid out, the push begun, the first frame of the
/// push shown, the first account of the conversation drawn, the transcript revealed and the push
/// over. One line in the `performance` log per open, written once the chat has both arrived and
/// shown its words, so a slow open on a phone in a pocket says which of those moments was late.
@MainActor
final class OpenTimeline {
    private var start = CACurrentMediaTime()
    private var marks: [(name: String, at: CFTimeInterval)] = []
    private var reported = false

    /// Counts from the press rather than from the moment the screen was made.
    func begin(at press: CFTimeInterval) {
        start = min(start, press)
    }

    func mark(_ name: String) {
        guard !reported, !marks.contains(where: { $0.name == name }) else { return }
        marks.append((name, CACurrentMediaTime()))
    }

    func reportIfComplete(session: String, rows: Int) {
        guard !reported, marks.contains(where: { $0.name == "revealed" }),
            marks.contains(where: { $0.name == "appeared" })
        else { return }
        reported = true
        let line = marks.map { "\($0.name)=\(Int((($0.at - start) * 1000).rounded()))" }
            .joined(separator: " ")
        MidgarLog.info("journey timeline session=\(session) rows=\(rows) \(line)", category: .performance)
    }
}
