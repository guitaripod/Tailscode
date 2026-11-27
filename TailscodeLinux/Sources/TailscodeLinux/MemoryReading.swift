import CGtkShim
import Foundation
import TailscodeCore

/// Where the process's memory stands, in one line, for the `memory` drive verb: what the kernel
/// counts resident, what malloc has in use, holds free and serves from its own mappings, and what
/// the caches the app keeps say they hold. `memory=trim` returns the free tails first and says
/// how much that gave back and how long it took; `memory=relieve` first asks everything in the
/// relief registry to let go of all it holds, as the governor does at its last level, and names
/// who answered.
enum MemoryReading {
    static func relieveAll() {
        let names = MemoryRelief.shared.relieve(.all)
        FileHandle.standardOutput.write(
            Data("RELIEF \(names.count): \(names.sorted().joined(separator: ", "))\n".utf8))
    }

    static func report(trim: Bool, shelved: Int) {
        var words: [String] = []
        if trim {
            let before = resident()
            let began = ContinuousClock.now
            _ = tailscode_heap_trim()
            let spent = ContinuousClock.now - began
            let milliseconds =
                Double(spent.components.seconds) * 1000
                + Double(spent.components.attoseconds) / 1_000_000_000_000_000
            words.append("trimmed=\((before - resident()) / 1024)M")
            words.append(String(format: "trimMs=%.1f", milliseconds))
        }
        words += [
            "rss=\(resident() / 1024)M",
            "heap=\(tailscode_heap_in_use() / 1_048_576)M",
            "heapFree=\(tailscode_heap_free() / 1_048_576)M",
            "heapMapped=\(tailscode_heap_mapped() / 1_048_576)M",
            "pictures=\(PictureStore.shared.cachedBytes / 1_048_576)M",
            "markdown=\(PangoMarkdown.cachedBytes / 1024)K",
            "syntax=\(PangoSyntax.cachedBytes / 1024)K",
            "shelved=\(shelved)",
            "returns=\(HeapReturn.passes.load(ordering: .relaxed))",
            "returnMs=\(Double(HeapReturn.lastMicroseconds.load(ordering: .relaxed)) / 1000)",
        ]
        FileHandle.standardOutput.write(Data(("MEMORY " + words.joined(separator: " ") + "\n").utf8))
    }

    /// The resident size in KiB, from the kernel's own account.
    private static func resident() -> Int {
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return 0
        }
        for line in text.split(separator: "\n") where line.hasPrefix("VmRSS:") {
            return Int(line.dropFirst(6).split(whereSeparator: \.isWhitespace).first ?? "") ?? 0
        }
        return 0
    }
}
