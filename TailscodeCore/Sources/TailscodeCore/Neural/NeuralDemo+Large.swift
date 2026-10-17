import CodingAgentKit
import Foundation

public extension NeuralDemo {
    /// One long user turn of about `steps` brain steps, for looking at a brain the size of a real
    /// day's work: reads, searches, edits, builds, a burst of shell calls, Task fan-outs, thoughts and
    /// notes, a few failures of which two thirds are run again word for word and pass, and the
    /// answer. Deterministic in `steps`, `prefix` and `origin`, with every id derived from them.
    static func largeTurn(
        steps: Int, prefix: String = "", origin: TimeInterval = 1_792_000_000, answer: Bool = true
    ) -> [ChatMessage] {
        LargeTurnScript(prefix: prefix, origin: origin, steps: max(steps, 20)).turn(answer: answer)
    }
}

private struct LargeTurnRandom {
    var state: UInt64

    init(seed: Int) {
        state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0xD1B5_4A32_D192_ED03
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(max(bound, 1)))
    }

    /// A number fixed by `a` and `b` alone, so a step's content never depends on its neighbours.
    static func hash(_ a: Int, _ b: Int) -> Int {
        var random = LargeTurnRandom(seed: a &* 7919 &+ b)
        return Int(random.next() >> 1)
    }
}

private enum LargeBeat: Equatable {
    case think, note, read, grep, glob, edit, write, shell, fetch, todo, skill
    case fan(group: Int, member: Int)
    case burst(member: Int)
    case failShell(pair: Int)
    case retryShell(pair: Int)
    case failRead, failEdit, failFetch, failCat
    case finish

    var isWords: Bool { self == .think || self == .note }

    var isSense: Bool { self == .read || self == .grep || self == .glob }
}

private struct LargeTurnScript {
    let prefix: String
    let origin: TimeInterval
    let steps: Int

    static let modules = [
        "TranscriptRows", "SessionListViewModel", "QuotaBoard", "NeuralLayout", "HomeBoard",
        "UpdateDriver", "ChatViewModel", "SendQueueStore", "TileGovernor", "SetupDesk",
        "SavedChatStore", "ForgeLight",
    ]

    static let thoughts = [
        "The failure points at {m}, so the cause is probably in how it is built rather than what it draws.",
        "Before touching {m} it is worth reading what already calls it, so the change stays narrow.",
        "Two readings of the error are possible; the cheaper one to rule out first is the stale build.",
        "{m} is shared by all three clients, which means the fix belongs in Core and the others only follow.",
        "The test names the behaviour exactly, so the edit can be checked against it before anything else moves.",
        "If the order of these calls matters, the fix has to keep it; a search for other callers will say.",
        "This is the third place the same guard is missing; one helper would remove all of them.",
        "Nothing here needs a new type. The value already carries what the caller is asking for.",
        "A rebuild of {m} will tell whether the earlier edit was enough or only moved the error.",
    ]

    static let notes = [
        "Reading the callers of {m} first.",
        "Found it; the guard is missing in two places, not one.",
        "Build is green, running the focused tests next.",
        "That failure is unrelated to this change; moving on.",
        "Checking the other clients answer the same case.",
        "The fixture needed one more row, adding it.",
        "Rebasing now that the tests pass.",
        "Looking at what the Mac manifest says about this.",
        "Cleaning up what the experiment left in the tree.",
    ]

    static let fanTasks = [
        "Review the diff for any switch that is still not exhaustive",
        "Find every caller of the changed initialiser across the three clients",
        "Read the release notes and list what a user would notice",
        "Check the Linux manifest answers every new capability",
        "Summarise how the settings file is written and what a flush costs",
        "Look for places that still compute this on the main thread",
        "Compare the transcript row builders on iOS and the desktops",
    ]

    static let fanAnswers = [
        "No other switch is affected.",
        "Three callers, all in the Linux client; none read the old field.",
        "Two notes worth keeping: the faster open and the quieter row.",
        "Every case is answered; one is a declared gap with its reason.",
        "A flush encodes the whole file once, off the GTK thread.",
        "One place left, in the refresh timer; the rest already hop off the main actor.",
    ]

    static let urls = [
        "https://developer.apple.com/documentation/uikit/uicollectionviewdiffabledatasource",
        "https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transfer-send-non-send.md",
        "https://docs.gtk.org/gtk4/class.LayoutManager.html",
        "https://ffmpeg.org/ffmpeg-filters.html",
        "https://www.swift.org/blog/swift-6-concurrency/",
    ]

    static let symbols = [
        "isChangingColumns", "flushPending", "ChatRowFacts", "PaneLifetime", "HomeBandLimits",
        "SessionMarks", "StreamCadence", "TileDrain", "UpdateLedger", "ForgeRing",
    ]

    static let todoItems = [
        "Reproduce the failure", "Read the callers", "Make the change in Core",
        "Answer it in each client", "Run the focused tests", "Install and check the version",
    ]

    static let answerLines = [
        "Done. The change is in Core and all three clients answer it; the focused tests pass.",
        "Two checks failed along the way and were never needed again; the rest were retried to green.",
    ]

    let burstCommands: [(String, [String])] = [
        ("git fetch origin", ["From github.com:guitaripod/Tailscode", "   4784c9c3..b3594f68  master -> origin/master"]),
        ("git status --short", [" M TailscodeCore/Sources/TailscodeCore/Neural/NeuralReadout.swift", " M TailscodeLinux/Sources/TailscodeLinux/BrainView.swift", "?? docs/world-clock-presentation/", "?? .tailscode/", " M TailscodeCore/Tests/TailscodeCoreTests/NeuralReadoutTests.swift"]),
        ("git diff --stat", [" TailscodeCore/Sources/TailscodeCore/Neural/NeuralReadout.swift | 42 ++++++++---", " TailscodeLinux/Sources/TailscodeLinux/BrainView.swift      | 18 +++--", " 2 files changed, 41 insertions(+), 19 deletions(-)", "", "warning: in the working copy of 'brain.c', LF will be replaced by CRLF"]),
        ("swift build --product TailscodeLinux 2>&1 | tail -8", ["[388/392] Compiling TailscodeLinux BrainView.swift", "[389/392] Compiling TailscodeLinux BrainCard.swift", "[390/392] Compiling TailscodeLinux BrainFooter.swift", "[391/392] Linking TailscodeLinux", "Build complete! (96.31s)"]),
        ("swift test --filter NeuralTurnsTests 2>&1 | tail -6", ["Test Suite 'NeuralTurnsTests' started", "Test Case 'NeuralTurnsTests.testSplitsTurns' passed (0.004 seconds)", "Test Case 'NeuralTurnsTests.testMarksRecovered' passed (0.002 seconds)", "Executed 11 tests, with 0 failures (0 unexpected) in 0.081 (0.083) seconds", "Test Suite 'All tests' passed"]),
        ("scripts/parity.sh --check", ["parity: 3 clients, 71 capabilities", "parity: every anchor found", "parity: ok"]),
        ("scripts/dev-linuxapp.sh status", ["running pid 38214", "rss 412 MB  threads 31  fds 118  windows 1"]),
        ("scripts/dev-linuxapp.sh shot out/shots/burst-07.png", ["out/shots/burst-07.png 1920x1080", "5 lines written to the harness log"]),
        ("ffprobe -v error -show_entries format=duration -of csv=p=0 out/demo/take-07.mp4", ["62.04"]),
        ("rg -c TODO TailscodeCore/Sources | sort -t: -k2 -nr | head -6", ["TailscodeCore/Sources/TailscodeCore/Neural/NeuralStepList.swift:3", "TailscodeCore/Sources/TailscodeCore/Parity.swift:2", "TailscodeCore/Sources/TailscodeCore/QuotaBoard.swift:1", "TailscodeCore/Sources/TailscodeCore/HomeBoard.swift:1", "TailscodeCore/Sources/TailscodeCore/Typography.swift:1"]),
        ("git log --oneline -n 6", ["4784c9c3 feat: ctrl+w v and ctrl+w s offer the terminal's folder", "b3594f68 feat: strings in ten languages for the brain's step list", "69450384 fix: a crash is written to the log and the app is gone at once", "5a1dd2fe perf: the decode gate serves the newest rows first", "3c142180 perf: the chat list's 10 s refresh waits while the window cannot be seen", "0d1e6a77 fix: a failure retires on nobody else's message"]),
        ("ls -la out/shots | tail -9", ["total 18420", "-rw-r--r-- 1 marcus marcus 2104331 Oct 17 09:12 burst-04.png", "-rw-r--r-- 1 marcus marcus 2118842 Oct 17 09:13 burst-05.png", "-rw-r--r-- 1 marcus marcus 2099127 Oct 17 09:14 burst-06.png", "-rw-r--r-- 1 marcus marcus 2131450 Oct 17 09:15 burst-07.png", "drwxr-xr-x 2 marcus marcus    4096 Oct 17 09:15 .", "drwxr-xr-x 5 marcus marcus    4096 Oct 17 09:10 .."]),
        ("du -sh .build", ["3.4G\t.build"]),
        ("scripts/soak-tiles.sh --quick 2>&1 | tail -7", ["soak: 8 panes, level 0", "soak: 60 s, rss 388 -> 396 MB", "soak: frame p95 7.1 ms", "soak: 0 stalls", "soak: ok"]),
    ]

    func date(_ n: Int) -> Date { Date(timeIntervalSince1970: origin + Double(n) * 18) }

    func user(_ n: Int, _ text: String) -> ChatMessage {
        ChatMessage(
            id: "\(prefix)u\(n)", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text(text))], createdAt: date(n), completedAt: date(n))
    }

    func message(_ n: Int, _ kinds: [MessagePart.Kind]) -> ChatMessage {
        ChatMessage(
            id: "\(prefix)m\(n)", role: .assistant, agentType: .claudeCode,
            parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
            createdAt: date(n), completedAt: date(n).addingTimeInterval(0.5))
    }

    func hash(_ index: Int, _ salt: Int) -> Int { LargeTurnRandom.hash(index, salt) }

    func module(_ index: Int) -> String {
        Self.modules[hash(index, 4) % Self.modules.count]
    }

    func path(_ index: Int) -> String {
        let name = module(index)
        switch hash(index, 5) % 4 {
        case 0: return "TailscodeCore/Sources/TailscodeCore/\(name).swift"
        case 1: return "TailscodeLinux/Sources/TailscodeLinux/\(name)View.swift"
        case 2: return "TailscodeMac/Sources/TailscodeMac/\(name)Pane.swift"
        default: return "TailscodeCore/Tests/TailscodeCoreTests/\(name)Tests.swift"
        }
    }

    func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    func lines(_ count: Int, _ make: (Int) -> String) -> [String] {
        (0..<count).map(make)
    }

    func count(_ index: Int, _ salt: Int, in range: ClosedRange<Int>) -> Int {
        range.lowerBound + hash(index, salt) % (range.upperBound - range.lowerBound + 1)
    }

    func tool(
        _ index: Int, _ name: String, _ input: [String: JSONValue], out: [String],
        status: ToolStatus = .completed
    ) -> MessagePart.Kind {
        .tool(
            ToolCall(
                id: "call-\(prefix)\(index)", name: name, status: status, input: .object(input),
                output: out.isEmpty ? nil : out.joined(separator: "\n")))
    }

    func bash(_ index: Int, _ command: String, out: [String], status: ToolStatus = .completed)
        -> MessagePart.Kind
    {
        tool(index, "Bash", ["command": .string(command)], out: out, status: status)
    }

    func layout() -> [LargeBeat?] {
        var slots = [LargeBeat?](repeating: nil, count: steps)
        var random = LargeTurnRandom(seed: steps)
        slots[0] = .think
        slots[steps - 1] = .finish
        let burstLength = steps >= 400 ? 14 : steps >= 60 ? 12 : steps / 5
        let burstStart = steps / 3
        for member in 0..<burstLength where burstStart + member < steps - 1 {
            slots[burstStart + member] = .burst(member: member)
        }
        func isFree(_ range: Range<Int>) -> Bool {
            range.lowerBound >= 1 && range.upperBound <= steps - 1
                && range.allSatisfy { slots[$0] == nil }
        }
        func nextFree(from start: Int) -> Int? {
            var cursor = max(start, 1)
            while cursor < steps - 1 {
                if slots[cursor] == nil { return cursor }
                cursor += 1
            }
            return nil
        }
        let fanOuts = steps >= 30 ? max(1, steps / 60) : 0
        for group in 0..<fanOuts {
            let size = 3 + random.below(3)
            var start = (group + 1) * steps / (fanOuts + 1) + random.below(5)
            while start + size < steps - 2 && !isFree(start..<(start + size)) { start += 1 }
            guard start + size < steps - 2 else { continue }
            for member in 0..<size { slots[start + member] = .fan(group: group, member: member) }
        }
        let failures = min(max(1, Int((0.045 * Double(steps)).rounded())), steps / 10)
        let stride = Double(steps - 14) / Double(max(failures, 1))
        var pair = 0
        var left = 0
        for index in 0..<failures {
            let base = 4 + Int(Double(index) * stride) + random.below(max(1, Int(stride / 2)))
            guard let spot = nextFree(from: base) else { continue }
            if index % 3 != 2 {
                let gap = 3 + random.below(4)
                guard let later = nextFree(from: spot + 1 + gap) else { continue }
                slots[spot] = .failShell(pair: pair)
                slots[later] = .retryShell(pair: pair)
                pair += 1
            } else {
                let kinds: [LargeBeat] = [.failRead, .failEdit, .failFetch, .failCat]
                slots[spot] = kinds[left % kinds.count]
                left += 1
            }
        }
        for index in 1..<(steps - 1) where slots[index] == nil {
            let previousWords = slots[index - 1]?.isWords ?? false
            let roll = random.below(100)
            switch roll {
            case 0..<8: slots[index] = previousWords ? .read : .think
            case 8..<14: slots[index] = previousWords ? .grep : .note
            case 14..<32: slots[index] = .read
            case 32..<42: slots[index] = .grep
            case 42..<46: slots[index] = .glob
            case 46..<60: slots[index] = .edit
            case 60..<64: slots[index] = .write
            case 64..<90: slots[index] = .shell
            case 90..<93: slots[index] = .fetch
            case 93..<96: slots[index] = .todo
            case 96..<97: slots[index] = .skill
            default: slots[index] = .shell
            }
        }
        return slots
    }

    func joins(_ beat: LargeBeat, at index: Int, after previous: LargeBeat, parts: Int) -> Bool {
        if previous.isWords && parts == 1 && !beat.isWords && beat != .finish { return true }
        switch (previous, beat) {
        case (.fan(let a, _), .fan(let b, _)): return a == b
        case (.burst, .burst(let member)): return member % 3 != 0
        default: break
        }
        return previous.isSense && beat.isSense && parts < 3 && hash(index, 6) % 3 == 0
    }

    func turn(answer: Bool) -> [ChatMessage] {
        let beats = layout().map { $0 ?? .read }
        var out: [ChatMessage] = [user(0, "Work through the whole backlog on the brain and ship it.")]
        var parts: [MessagePart.Kind] = []
        var previous: LargeBeat?
        var number = 1
        func flush() {
            guard !parts.isEmpty else { return }
            out.append(message(number, parts))
            number += 1
            parts = []
        }
        for (index, beat) in beats.enumerated() {
            if let previous, !joins(beat, at: index, after: previous, parts: parts.count) { flush() }
            parts.append(kind(of: beat, at: index))
            previous = beat
        }
        flush()
        if answer {
            let total = beats.count
            out.append(
                message(
                    number,
                    [
                        .text(Self.answerLines[0]),
                        .text("\(Self.answerLines[1]) \(total) steps in all."),
                    ]))
        }
        return out
    }

    func kind(of beat: LargeBeat, at index: Int) -> MessagePart.Kind {
        let name = module(index)
        switch beat {
        case .think:
            return .reasoning(Self.thoughts[hash(index, 1) % Self.thoughts.count].replacingOccurrences(of: "{m}", with: name))
        case .note:
            return .text(Self.notes[hash(index, 1) % Self.notes.count].replacingOccurrences(of: "{m}", with: name))
        case .read:
            return read(index)
        case .grep:
            return grep(index)
        case .glob:
            return glob(index)
        case .edit:
            return edit(index)
        case .write:
            return write(index)
        case .shell:
            let (command, output) = shell(index)
            return bash(index, command, out: output)
        case .fetch:
            return fetch(index)
        case .todo:
            return todo(index)
        case .skill:
            let skill = ["parity", "frames-cli", "design"][hash(index, 7) % 3]
            return tool(index, "Skill", ["skill": .string(skill)], out: ["Launching skill: \(skill)"])
        case .fan(let group, let member):
            return fan(index, group: group, member: member)
        case .burst(let member):
            let (command, output) = burstCommands[member % burstCommands.count]
            return bash(index, command, out: output)
        case .failShell(let pair):
            let recipe = retryRecipe(pair)
            return bash(index, recipe.command, out: recipe.failed, status: .error)
        case .retryShell(let pair):
            let recipe = retryRecipe(pair)
            return bash(index, recipe.command, out: recipe.passed)
        case .failRead:
            let missing = "docs/\(lowerFirst(name))-\(index).md"
            return tool(
                index, "Read", ["file_path": .string(missing)],
                out: ["File does not exist: \(missing)"], status: .error)
        case .failEdit:
            let target = path(index)
            return tool(
                index, "Edit",
                [
                    "file_path": .string(target),
                    "old_string": .string("    private var pending\(index): [String] = []"),
                    "new_string": .string("    private var pending\(index): Set<String> = []"),
                ],
                out: ["String to replace not found in file.", "String:     private var pending\(index): [String] = []"],
                status: .error)
        case .failFetch:
            let url = "https://docs.example.dev/\(lowerFirst(name))/\(index)"
            return tool(
                index, "WebFetch", ["url": .string(url), "prompt": .string("What does this page say about \(name)?")],
                out: ["Request failed with status code 404", url], status: .error)
        case .failCat:
            let missing = "docs/notes-\(index).txt"
            return bash(index, "cat \(missing)", out: ["cat: \(missing): No such file or directory"], status: .error)
        case .finish:
            return bash(
                index, "scripts/install-linuxapp.sh",
                out: ["Building release", "Installing to ~/.local/share/tailscode", "Restarting the app", "Installed Tailscode 1.79, pid 41876"])
        }
    }

    func read(_ index: Int) -> MessagePart.Kind {
        let target = path(index)
        let name = module(index)
        let shown = count(index, 8, in: 3...8)
        let output = lines(shown) { n in
            let body = [
                "import Foundation", "", "public struct \(name) {", "    private let limit = 20",
                "    public init() {}", "    func refresh() async {", "        let rows = await load()",
                "        apply(rows)",
            ]
            return String(format: "%6d\t", n + 1) + body[n % body.count]
        }
        return tool(index, "Read", ["file_path": .string(target)], out: output)
    }

    func grep(_ index: Int) -> MessagePart.Kind {
        let symbol = Self.symbols[hash(index, 9) % Self.symbols.count]
        let found = count(index, 10, in: 2...9)
        let output = lines(found) { n in
            "\(path(index + n * 17 + 1)):\(40 + hash(index, 11 + n) % 400): \(symbol)"
        }
        let root = ["TailscodeCore/Sources", "TailscodeLinux/Sources", "TailscodeMac/Sources"][hash(index, 12) % 3]
        return tool(index, "Grep", ["pattern": .string(symbol), "path": .string(root)], out: output)
    }

    func glob(_ index: Int) -> MessagePart.Kind {
        let name = module(index)
        let found = count(index, 13, in: 2...6)
        let output = lines(found) { n in path(index + n * 29 + 3) }
        return tool(index, "Glob", ["pattern": .string("**/*\(name)*.swift")], out: output)
    }

    func edit(_ index: Int) -> MessagePart.Kind {
        let name = module(index)
        let variable = lowerFirst(name)
        let (old, new): (String, String)
        switch hash(index, 14) % 6 {
        case 0:
            old = "    private let limit = \(10 + index % 20)"
            new = "    private let limit = \(30 + index % 20)"
        case 1:
            old = "    func refresh() async {\n        let rows = await load()\n        apply(rows)\n    }"
            new = "    func refresh() async {\n        guard !isRefreshing else { return }\n        isRefreshing = true\n        defer { isRefreshing = false }\n        let rows = await load()\n        apply(rows)\n    }"
        case 2:
            old = "        if rows.isEmpty { return nil }\n        return rows[0]"
            new = "        guard let first = rows.first else { return nil }\n        return first"
        case 3:
            old = "    public var \(variable)Count: Int"
            new = "    public var \(variable)Count: Int\n    public var \(variable)Revision: Int = 0"
        case 4:
            old = "        case .idle: return nil\n        case .running: return \"working\""
            new = "        case .idle: return nil\n        case .background: return \"in the background\"\n        case .running: return \"working\""
        default:
            old = "        let sorted = rows.sorted { $0.at < $1.at }\n        return sorted"
            new = "        return rows.sorted { $0.at < $1.at }"
        }
        let target = path(index)
        return tool(
            index, "Edit",
            ["file_path": .string(target), "old_string": .string(old), "new_string": .string(new)],
            out: ["The file \(target) has been updated."])
    }

    func write(_ index: Int) -> MessagePart.Kind {
        let name = module(index)
        let target = "TailscodeCore/Tests/TailscodeCoreTests/\(name)Fixture\(index).swift"
        let content = [
            "import Foundation", "@testable import TailscodeCore", "",
            "enum \(name)Fixture\(index) {",
            "    static let rows = [\"a\", \"b\", \"c\", \"\(index)\"]",
            "    static let limit = \(10 + index % 40)", "}", "",
        ].joined(separator: "\n")
        return tool(
            index, "Write", ["file_path": .string(target), "content": .string(content)],
            out: ["File created successfully at: \(target)"])
    }

    func fetch(_ index: Int) -> MessagePart.Kind {
        let url = Self.urls[hash(index, 15) % Self.urls.count]
        let output = lines(count(index, 16, in: 2...4)) { n in
            ["The page describes the supported API surface.", "It names the main constraint on ordering.", "An example shows the call with its arguments.", "A note says the behaviour changed in the last release."][n % 4]
        }
        return tool(
            index, "WebFetch", ["url": .string(url), "prompt": .string("What does this say that matters for \(module(index))?")],
            out: output)
    }

    func todo(_ index: Int) -> MessagePart.Kind {
        let done = hash(index, 17) % Self.todoItems.count
        let items: [JSONValue] = Self.todoItems.enumerated().map { offset, text in
            .object([
                "content": .string(text),
                "status": .string(offset < done ? "completed" : offset == done ? "in_progress" : "pending"),
                "activeForm": .string(text),
            ])
        }
        return tool(index, "TodoWrite", ["todos": .array(items)], out: ["Todos have been modified successfully."])
    }

    func fan(_ index: Int, group: Int, member: Int) -> MessagePart.Kind {
        let description = Self.fanTasks[(group * 3 + member) % Self.fanTasks.count]
        let answer = Self.fanAnswers[hash(index, 18) % Self.fanAnswers.count]
        return tool(
            index, "Task",
            ["description": .string(description), "subagent_type": .string("general-purpose")],
            out: [answer])
    }

    func shell(_ index: Int) -> (String, [String]) {
        let name = module(index)
        let target = path(index)
        switch hash(index, 19) % 12 {
        case 0:
            let total = count(index, 20, in: 8...30)
            return (
                "swift build --target \(name) 2>&1 | tail -30",
                lines(total) { n in
                    n == total - 1
                        ? "Build complete! (\(20 + hash(index, 21) % 180).\(hash(index, 22) % 10)s)"
                        : "[\(n + 1)/\(total)] Compiling \(name) \(module(index + n + 1)).swift"
                })
        case 1:
            let tests = count(index, 23, in: 4...14)
            return (
                "swift test --filter \(name)Tests 2>&1 | tail -20",
                lines(tests) { n in
                    "Test Case '\(name)Tests.test\(n + 1)' passed (0.00\(1 + n % 9) seconds)"
                } + ["Executed \(tests) tests, with 0 failures (0 unexpected) in 0.0\(40 + index % 50) seconds"])
        case 2:
            return (
                "git status --short",
                lines(count(index, 24, in: 5...12)) { n in
                    (n % 4 == 3 ? "?? " : " M ") + path(index + n + 1)
                })
        case 3:
            let changed = count(index, 25, in: 3...9)
            return (
                "git diff --stat",
                lines(changed) { n in
                    " \(path(index + n + 2)) | \(4 + hash(index, 26 + n) % 60) ++++---"
                } + [" \(changed) files changed, \(60 + index % 90) insertions(+), \(10 + index % 40) deletions(-)"])
        case 4:
            return (
                "git log --oneline -n 8",
                lines(8) { n in
                    String(format: "%08x", hash(index, 30 + n) & 0xFFFF_FFFF) + " "
                        + ["fix: a failure retires on nobody else's message", "perf: the decode gate serves the newest rows first", "feat: strings in ten languages", "fix: the row pressed is the row opened"][n % 4]
                })
        case 5:
            let symbol = Self.symbols[hash(index, 31) % Self.symbols.count]
            return (
                "rg -n \"\(symbol)\" TailscodeCore/Sources | head -20",
                lines(count(index, 32, in: 5...20)) { n in
                    "\(path(index + n * 7 + 2)):\(30 + hash(index, 40 + n) % 500):    \(symbol)"
                })
        case 6:
            let frames = 400 + hash(index, 33) % 1800
            return (
                "ffmpeg -y -i out/clips/take-\(index).mov -vf fps=30 out/clips/take-\(index).mp4",
                [
                    "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'out/clips/take-\(index).mov':",
                    "  Duration: 00:00:\(10 + index % 50).00, start: 0.000000, bitrate: 21540 kb/s",
                    "  Stream #0:0: Video: hevc, yuv420p10le, 1170x2532, 60 fps",
                    "Output #0, mp4, to 'out/clips/take-\(index).mp4':",
                    "frame= \(frames) fps= 58 q=28.0 size=   10240kB time=00:00:\(frames / 30 % 60) bitrate=2800.0kbits/s",
                    "video:19.4MiB audio:0kB subtitle:0kB other streams:0kB global headers:0kB muxing overhead: 0.3%",
                ])
        case 7:
            return (
                "ls -la TailscodeCore/Sources/TailscodeCore | head -30",
                ["total 2840"]
                    + lines(count(index, 34, in: 6...30)) { n in
                        "-rw-r--r-- 1 marcus marcus \(1200 + hash(index, 50 + n) % 40000) Oct 17 09:\(10 + n % 50) \(module(index + n + 5)).swift"
                    })
        case 8:
            return (
                "wc -l \(target)",
                ["  \(60 + hash(index, 35) % 700) \(target)"])
        case 9:
            return (
                "scripts/parity.sh",
                ["parity: 3 clients, 71 capabilities", "  ios        implemented 66  partial 3  gap 1  n/a 1", "  linux      implemented 64  partial 4  gap 2  n/a 1", "  mac        implemented 67  partial 2  gap 1  n/a 1", "  mac-store  implemented 66  partial 2  gap 1  n/a 2"])
        case 10:
            return (
                "xcodegen generate",
                ["Loaded project:", "  Name: Tailscode", "  Targets: 6", "Generating project Tailscode", "Created project at Tailscode.xcodeproj"])
        default:
            return (
                "python3 scripts/beats.py --grid \(index % 9 + 1).25 --bars 16",
                ["tempo 115.0", "grid \(index % 9 + 1).25 s", "16 bars", "first accent at \(index % 9 + 1).27 s"])
        }
    }

    func retryRecipe(_ pair: Int) -> (command: String, failed: [String], passed: [String]) {
        let name = Self.modules[(pair / 6) % Self.modules.count]
        let line = 100 + hash(pair, 60) % 600
        switch pair % 6 {
        case 0:
            return (
                "swift build -c release 2>&1 | tail -20",
                [
                    "TailscodeCore/Sources/TailscodeCore/\(name).swift:\(line):17: error: switch must be exhaustive",
                    "                switch kind {",
                    "                ^",
                    "TailscodeCore/Sources/TailscodeCore/\(name).swift:\(line):17: note: add missing case: '.note(_)'",
                    "error: fatalError",
                ],
                (0..<8).map { "[\($0 + 1)/9] Compiling TailscodeCore \(module(pair * 5 + $0)).swift" }
                    + ["Build complete! (212.4s)"])
        case 1:
            return (
                "swift test --filter \(name)Tests",
                [
                    "Test Case '\(name)Tests.testOrdering' started.",
                    "TailscodeCore/Tests/TailscodeCoreTests/\(name)Tests.swift:\(line): error: -[\(name)Tests testOrdering] : XCTAssertEqual failed: (\"3\") is not equal to (\"4\")",
                    "Test Case '\(name)Tests.testOrdering' failed (0.003 seconds).",
                    "Executed 9 tests, with 1 failure (0 unexpected) in 0.071 (0.073) seconds",
                    "error: fatalError",
                ],
                [
                    "Test Case '\(name)Tests.testOrdering' passed (0.002 seconds).",
                    "Executed 9 tests, with 0 failures (0 unexpected) in 0.069 (0.071) seconds",
                    "Test Suite 'All tests' passed",
                ])
        case 2:
            return (
                "ffmpeg -f concat -i out/demo/cut-list-\(pair).txt -i out/demo/track.flac -map 1:a -shortest out/demo/final-\(pair).mp4",
                [
                    "Input #0, concat, from 'out/demo/cut-list-\(pair).txt':",
                    "Stream map '1:a' matches no streams.",
                    "To ignore this, add a trailing '?' to the map.",
                ],
                [
                    "Output #0, mp4, to 'out/demo/final-\(pair).mp4':",
                    "frame= 1860 fps= 61 q=-1.0 Lsize=   20480kB time=00:01:02.04 bitrate=2703.5kbits/s",
                    "video:19.4MiB audio:1.4MiB subtitle:0kB other streams:0kB muxing overhead: 0.2%",
                ])
        case 3:
            return (
                "git rebase origin/master",
                [
                    "error: cannot rebase: You have unstaged changes.",
                    "error: Please commit or stash them.",
                ],
                [
                    "Successfully rebased and updated refs/heads/master.",
                ])
        case 4:
            return (
                "scripts/parity.sh --check",
                [
                    "parity: mac answers no case for .\(lowerFirst(name))",
                    "parity: 1 capability without an answer",
                    "exit 1",
                ],
                ["parity: 3 clients, 71 capabilities", "parity: every anchor found", "parity: ok"])
        default:
            return (
                "swift package resolve",
                [
                    "Fetching https://github.com/guitaripod/CodingAgentKit.git",
                    "error: Failed to clone repository https://github.com/guitaripod/CodingAgentKit.git:",
                    "fatal: unable to access 'https://github.com/guitaripod/CodingAgentKit.git/': Could not resolve host: github.com",
                ],
                [
                    "Fetching https://github.com/guitaripod/CodingAgentKit.git from cache",
                    "Fetched https://github.com/guitaripod/CodingAgentKit.git from cache (0.82s)",
                    "Computing version for https://github.com/guitaripod/CodingAgentKit.git",
                    "Computed https://github.com/guitaripod/CodingAgentKit.git at 0.39.0 (0.41s)",
                ])
        }
    }
}
