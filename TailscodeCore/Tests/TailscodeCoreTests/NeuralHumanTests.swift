import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural human: shell commands")
struct NeuralHumanCommandTests {
    private static let samples: [(String, String)] = [
        ("swift build -c release 2>&1 | tail -20", "Built the project"),
        ("cd TailscodeCore && swift build", "Built the project"),
        ("cd x && swift test --filter Foo", "Ran the tests"),
        ("TMPDIR=/home/marcus/x swift test --scratch-path y --filter Neural", "Ran the tests"),
        ("time swift build", "Built the project"),
        ("sudo make install", "Installed"),
        ("xcodebuild -scheme Tailscode build", "Built the project"),
        ("xcodebuild test -scheme Tailscode", "Ran the tests"),
        ("cargo build --release", "Built the project"),
        ("cargo test", "Ran the tests"),
        ("cargo clippy -- -D warnings", "Ran the linter"),
        ("make", "Built the project"),
        ("make -j8 all", "Built the project"),
        ("make test", "Ran the tests"),
        ("make clean", "Ran make"),
        ("npm run build", "Built the project"),
        ("npm test", "Ran the tests"),
        ("npm run lint", "Ran the linter"),
        ("npm install", "Installed"),
        ("npm install left-pad", "Installed left-pad"),
        ("yarn test", "Ran the tests"),
        ("pnpm build", "Built the project"),
        ("pytest -q", "Ran the tests"),
        ("python3 -m pytest tests/", "Ran the tests"),
        ("jest --watch", "Ran the tests"),
        ("go test ./...", "Ran the tests"),
        ("go build ./...", "Built the project"),
        ("gradle test", "Ran the tests"),
        ("tsc --noEmit", "Built the project"),
        ("swiftlint", "Ran the linter"),
        ("eslint src", "Ran the linter"),
        ("ruff check .", "Ran the linter"),
        ("git status", "Checked git status"),
        ("git status --short", "Checked git status"),
        ("git diff HEAD~1", "Looked at the diff"),
        ("git -C repo diff", "Looked at the diff"),
        ("git --no-pager diff --stat", "Looked at the diff"),
        ("git commit -m 'a message with && and ; in it'", "Committed"),
        ("git push origin master", "Pushed"),
        ("git log --oneline -5", "Ran git log"),
        ("git add -A && git commit -m x", "Ran git add"),
        ("brew install ripgrep", "Installed ripgrep"),
        ("apt-get install -y jq", "Installed jq"),
        ("pip3 install requests", "Installed requests"),
        ("cargo install ripgrep", "Installed ripgrep"),
        ("rg -n demo scripts", "Searched the files"),
        ("grep -r foo .", "Searched the files"),
        ("find . -name '*.swift'", "Searched the files"),
        ("ls -la", "Looked at files"),
        ("cat README.md", "Looked at files"),
        ("sed -n 1,60p scripts/film.sh", "Looked at files"),
        ("head -20 file", "Looked at files"),
        ("tail -f log", "Looked at files"),
        ("wc -l file", "Looked at files"),
        ("curl -s https://example.dev", "Fetched a page"),
        ("wget https://example.dev/a.zip", "Fetched a page"),
        ("ffmpeg -i a.mov -c copy b.mp4", "Ran ffmpeg"),
        ("ffprobe -v error -show_streams a.mov", "Ran ffprobe"),
        ("./scripts/foo.sh", "Ran foo.sh"),
        ("scripts/install-linuxapp.sh", "Ran install-linuxapp.sh"),
        ("bash scripts/x.sh --flag", "Ran x.sh"),
        ("python3 scripts/beats.py --grid 8.75 --bars 16", "Ran beats.py"),
        ("node build.js", "Ran build.js"),
        ("docker ps", "Ran docker"),
        ("frames doctor", "Ran frames"),
        ("scripts/dev-linuxapp.sh shot out/demo/01.png", "Ran dev-linuxapp.sh"),
        ("FOO=1 BAR=2 ./run.sh", "Ran run.sh"),
        ("env X=1 swift build", "Built the project"),
        ("cd a && cd b && make test", "Ran the tests"),
        ("(cd x && make)", "Built the project"),
        ("echo hi; swift test", "Ran echo"),
        ("swift build 2>&1 | grep error", "Built the project"),
        ("cat x | rg foo", "Looked at files"),
        ("sudo -u bob make test", "Ran the tests"),
        ("timeout 30 swift test", "Ran the tests"),
        ("sed -i s/a/b/ f", "Ran sed"),
        ("mkdir -p out/demo", "Ran mkdir"),
        ("rm -rf build", "Ran rm"),
        ("systemctl --user restart claude-bridge", "Ran systemctl"),
        ("xcodegen", "Ran xcodegen"),
        ("swift package resolve", "Ran swift"),
        ("export A=1 && ./go.sh", "Ran go.sh"),
        ("# a comment\nmake test", "Ran the tests"),
        ("cd /tmp", "Ran a command"),
        ("", "Ran a command"),
    ]

    @Test("at least sixty commands read as the sentence the table gives")
    func samples() {
        #expect(Self.samples.count >= 60)
        for (command, expected) in Self.samples {
            let cls = NeuralHuman.classify(command)
            #expect(NeuralHuman.title(of: cls) == expected, "\(command) -> \(NeuralHuman.title(of: cls))")
        }
    }

    @Test("the first meaningful program is named past env prefixes, cd chains, sudo, time and pipes")
    func program() {
        #expect(NeuralHuman.program(of: "FOO=1 sudo -E ./scripts/foo.sh a b") == "foo.sh")
        #expect(NeuralHuman.program(of: "cd x && time swift build | tail") == "swift")
        #expect(NeuralHuman.program(of: "cd /tmp") == nil)
        #expect(NeuralHuman.program(of: "docker ps | grep x") == "docker")
    }

    @Test("check kinds are the builds, the tests and the linters")
    func checkKinds() {
        #expect(NeuralHuman.classify("swift build").checkKind == .build)
        #expect(NeuralHuman.classify("pytest").checkKind == .test)
        #expect(NeuralHuman.classify("swiftlint").checkKind == .lint)
        #expect(NeuralHuman.classify("git status").checkKind == nil)
        #expect(NeuralHuman.CheckKind.build.title == "Built the project")
        #expect(NeuralHuman.CheckKind.test.againTitle == "Ran the tests again")
    }

    @Test("quotes keep their words whole and operators inside them do not split")
    func quoting() {
        #expect(NeuralHuman.heads(of: "echo 'a && b' && make").map { $0.first } == ["echo", "make"])
        #expect(NeuralHuman.heads(of: "a | b | c; d || e").map { $0.first } == ["a", "d", "e"])
        #expect(NeuralHuman.heads(of: "make 2>&1 | tee log").count == 1)
    }
}

@Suite("Neural human: titles")
struct NeuralHumanTitleTests {
    typealias NF = NeuralTurnFixtures

    private func steps(_ parts: [MessagePart.Kind]...) -> [NeuralStep] {
        var messages = [NF.user(0)]
        for (offset, kinds) in parts.enumerated() { messages.append(NF.message(offset + 1, kinds)) }
        messages.append(NF.message(parts.count + 1, [.text("done")]))
        return NeuralTurns.partition(messages: messages, running: false)[0].steps
    }

    @Test("the file and search tools read as sentences with the raw argument kept beside them")
    func tools() {
        let list = steps(
            [NF.read("docs/film.sh", out: ["1"])], [NF.grep("compaction", in: "Sources", out: ["a"])],
            [NF.edit("out/demo/cut-list.json", added: 4, removed: 1)],
            [NF.tool("Write", ["file_path": .string("out/tailscode-demo.mp4"), "content": .string("x")], out: ["ok"])],
            [NF.tool("Glob", ["path": .string("src/Chat")], out: ["a"])],
            [NF.tool("WebFetch", ["url": .string("https://example.com/a/b")], out: ["x"])],
            [NF.tool("WebSearch", ["query": .string("swift concurrency")], out: ["x"])],
            [NF.task("Review the diff for gaps", out: ["ok"])],
            [NF.skill("frames-cli", out: ["ok"])],
            [NF.tool("TodoWrite", ["todos": .array([])], out: ["ok"])],
            [NF.tool("TaskList", [:], out: ["ok"])],
            [NF.tool("Mystery", ["x": .string("y")], out: ["ok"])])
        let titles = NeuralHuman.titles(for: list).map(\.text)
        #expect(titles == [
            "Read film.sh", "Searched for compaction", "Edited cut-list.json (+4 \u{2212}1)",
            "Wrote tailscode-demo.mp4", "Listed Chat", "Fetched example.com", "Searched the web for swift concurrency",
            "Asked an agent: Review the diff for gaps", "Used the frames-cli skill", "Updated its plan",
            "Looked at its plan", "Used Mystery",
        ])
        #expect(NeuralHuman.titles(for: list).map(\.raw).prefix(3) == ["Read", "Grep", "Edit"])
        #expect(NeuralHuman.titles(for: list)[0].secondary == "docs/film.sh")
    }

    @Test("a command run again after a failed run of itself reads as a retry")
    func retries() {
        let list = steps(
            [NF.bash("swift build", out: ["error: x"], status: .error)], [NF.bash("swift build", out: ["ok"])],
            [NF.bash("swift test", out: ["error: x"], status: .error)], [NF.bash("swift test", out: ["ok"])],
            [NF.bash("./scripts/foo.sh", out: ["error: x"], status: .error)], [NF.bash("./scripts/foo.sh", out: ["ok"])],
            [NF.bash("git commit -m x", out: ["error: x"], status: .error)], [NF.bash("git commit -m x", out: ["ok"])],
            [NF.bash("swiftlint", out: ["error: x"], status: .error)], [NF.bash("swiftlint", out: ["ok"])])
        let titles = NeuralHuman.titles(for: list).map(\.text)
        #expect(titles == [
            "Built the project", "Ran the build again", "Ran the tests", "Ran the tests again",
            "Ran foo.sh", "Ran foo.sh again", "Committed", "Committed again", "Ran the linter",
            "Ran the linter again",
        ])
        #expect(NeuralHuman.title(at: 1, in: list).text == "Ran the build again")
        #expect(NeuralHuman.title(for: list[1]) == "Built the project")
        #expect(NeuralHuman.isRetry(at: 1, in: list) && !NeuralHuman.isRetry(at: 0, in: list))
        let same = steps([NF.bash("swift build", out: ["ok"])], [NF.bash("swift build", out: ["ok"])])
        #expect(NeuralHuman.titles(for: same).map(\.text) == ["Built the project", "Built the project"])
    }

    @Test("thoughts and notes keep their own words, and a step with no argument reads in general terms")
    func words() {
        let list = steps([.reasoning("hm")], [.text("note")], [NF.tool("Read", [:], out: ["x"])],
            [NF.tool("Edit", [:], out: ["x"])], [NF.tool("Grep", [:], out: ["x"])])
        #expect(NeuralHuman.titles(for: list).map(\.text) == [
            "Thinking", "Said", "Read a file", "Edited a file", "Searched the files",
        ])
    }

    @Test("the real shell steps of the demos and the large demo all read as something")
    func demos() {
        var seen = 0
        let messages = NeuralDemo.buildFix() + NeuralDemo.turn(prefix: "t-") + NeuralDemo.largeTurn(steps: 174, prefix: "l-")
        for turn in NeuralTurns.partition(messages: messages, running: false) {
            let titles = NeuralHuman.titles(for: turn.steps)
            for (index, step) in turn.steps.enumerated() where step.zone == .shell {
                seen += 1
                #expect(titles[index].text != "Ran a command", "\(step.detail)")
                #expect(!titles[index].text.isEmpty)
                #expect(titles[index].raw == "Bash" || titles[index].raw.isEmpty == false)
            }
        }
        #expect(seen > 40)
    }

    @Test("titles of a 2,000-step turn are read in one linear pass")
    func linear() {
        let list = StepListFixtures.synthetic(2_000)
        let clock = ContinuousClock()
        var titles: [NeuralHuman.Title] = []
        let elapsed = clock.measure { titles = NeuralHuman.titles(for: list) }
        #expect(titles.count == 2_000)
        let parts = elapsed.components
        #expect(Double(parts.seconds) + Double(parts.attoseconds) / 1e18 < 1)
    }
}
