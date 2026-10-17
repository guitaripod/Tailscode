import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural provenance")
struct NeuralProvenanceTests {
    typealias Fixtures = NeuralTurnFixtures

    private func texts(_ text: String) -> [String] {
        NeuralProvenance.tokens(in: text).map(\.text)
    }

    @Test("the TURN's answer names two files")
    func answerTokens() {
        let found = Fixtures.answer.flatMap(texts)
        #expect(found == ["out/demo/tailscode-demo.mp4", "out/demo/cut-list.json"])
    }

    @Test("quotes, brackets, closing punctuation and a line number are trimmed")
    func trimming() {
        #expect(texts("see `scripts/film.sh`, then") == ["scripts/film.sh"])
        #expect(texts("(out/demo/tailscode-demo.mp4).") == ["out/demo/tailscode-demo.mp4"])
        #expect(texts("\"docs/neural-trace.md\"; and") == ["docs/neural-trace.md"])
        #expect(texts("**Sources/Chat/TranscriptRows.swift**") == ["Sources/Chat/TranscriptRows.swift"])
        #expect(texts("at TranscriptRows.swift:212 it stops") == ["TranscriptRows.swift"])
        #expect(texts("at Sources/Rows.swift:212:9: it stops") == ["Sources/Rows.swift"])
        #expect(texts("run ./scripts/dev-linuxapp.sh now") == ["./scripts/dev-linuxapp.sh"])
        #expect(texts("in ~/Dev/film/walk.mp4!") == ["~/Dev/film/walk.mp4"])
    }

    @Test("a token carries its place in the text")
    func ranges() {
        let text = "First out/demo/cut-list.json, then docs/neural-trace.md."
        let tokens = NeuralProvenance.tokens(in: text)
        #expect(tokens.count == 2)
        #expect(tokens.map { String(text[$0.range]) } == tokens.map(\.text))
        #expect(tokens[0].range.lowerBound == text.index(text.startIndex, offsetBy: 6))
    }

    @Test("names ending in a known extension count, others do not")
    func extensions() {
        for ending in ["mp4", "swift", "json", "flac", "sh", "md", "ts", "py", "rs", "c", "h", "yml", "toml", "png", "jpg", "txt"] {
            #expect(texts("open cut-list.\(ending) now") == ["cut-list.\(ending)"], "\(ending)")
        }
        #expect(texts("open README.MD now") == ["README.MD"])
        #expect(texts("open walk-through.mov now").isEmpty)
        #expect(texts("open archive.swiftx now").isEmpty)
    }

    @Test("short words, plain prose and numbers are not paths")
    func notPaths() {
        #expect(texts("a/b and/or x.sh 3840×2160 8.75 1.2.3 e.g. i.e.").isEmpty)
        #expect(texts("It took 62 s at 30 fps, then ended.").isEmpty)
        #expect(texts("").isEmpty)
        #expect(texts("   \n  ").isEmpty)
    }

    @Test("a path across lines is found on each line")
    func multiline() {
        #expect(texts("one\nsrc/a/b.swift\n\nsrc/c/d.swift") == ["src/a/b.swift", "src/c/d.swift"])
    }

    @Test("steps touching a token are those whose argument or output holds it")
    func touching() {
        let steps = Fixtures.steps(Fixtures.turn())
        let cut = NeuralProvenance.steps(touching: "out/demo/cut-list.json", in: steps)
        #expect(cut == steps.filter { $0.tieKey == "out/demo/cut-list.json" }.map(\.id))
        #expect(cut.count == 3)
        let video = NeuralProvenance.steps(touching: "out/demo/tailscode-demo.mp4", in: steps)
        #expect(video.count == 3)
        #expect(video.allSatisfy { id in steps.first { $0.id == id }?.zone == .shell })
        let shot = NeuralProvenance.steps(touching: "out/demo/01.png", in: steps)
        #expect(shot.count == 1)
        let printed = NeuralProvenance.steps(touching: "started pid 38214", in: steps)
        #expect(printed.count == 1)
    }

    @Test("matching is a literal, case-sensitive substring and nothing more")
    func literal() {
        let steps = Fixtures.steps(Fixtures.turn())
        #expect(NeuralProvenance.steps(touching: "Out/Demo/cut-list.json", in: steps).isEmpty)
        #expect(NeuralProvenance.steps(touching: "cut-list", in: steps).count == 5)
        #expect(NeuralProvenance.steps(touching: "", in: steps).isEmpty)
        #expect(NeuralProvenance.steps(touching: "no/such/file.swift", in: steps).isEmpty)
        let thought = NeuralStep(
            id: "t", index: 0, zone: .think, group: 0, messageID: "m", title: "Thinking",
            text: "look at src/a/b.swift")
        #expect(NeuralProvenance.steps(touching: "src/a/b.swift", in: [thought]).isEmpty)
        let ls = NeuralStep(
            id: "x", index: 0, zone: .shell, group: 0, messageID: "m", title: "Bash", detail: "ls src",
            outputLines: ["src/a/b.swift"])
        #expect(NeuralProvenance.steps(touching: "src/a/b.swift", in: [thought, ls]) == ["x"])
    }

    @Test("an answer's tokens find their steps end to end")
    func endToEnd() {
        let steps = Fixtures.steps(Fixtures.turn())
        let tokens = Fixtures.answer.flatMap(NeuralProvenance.tokens(in:))
        let lit = tokens.map { NeuralProvenance.steps(touching: $0.text, in: steps).count }
        #expect(lit == [3, 3])
    }
}
