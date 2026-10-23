import CodingAgentKit
import Foundation

/// What a step did, as a sentence a person reads: "Read film.sh", "Searched for compaction",
/// "Built the project", "Ran the build again". The raw tool and argument stay beside it as the
/// secondary line. The words come from the call's kind, its name and its arguments and nothing
/// else: a command is classified by its first meaningful program, never guessed at past that.
public enum NeuralHuman {
    /// What kind of command a shell step ran.
    public enum CommandClass: Sendable, Equatable {
        case build
        case test
        case lint
        case gitStatus
        case gitDiff
        case gitCommit
        case gitPush
        /// Another git subcommand, by name.
        case gitOther(String)
        /// An install, of a package when exactly one was named.
        case install(String?)
        case search
        case look
        case fetch
        /// ffmpeg and ffprobe, by program.
        case media(String)
        /// A script run by path or through an interpreter, by file name.
        case script(String)
        case other(String)
        /// A command with no program in it.
        case none

        /// Whether it is a check a result reports: a build, the tests, a linter.
        public var checkKind: CheckKind? {
            switch self {
            case .build: return .build
            case .test: return .test
            case .lint: return .lint
            default: return nil
            }
        }
    }

    public enum CheckKind: Sendable, Equatable, CaseIterable {
        case build
        case test
        case lint

        /// "Built the project", "Ran the tests", "Ran the linter".
        public var title: String {
            switch self {
            case .build: return NeuralReading.humanBuilt
            case .test: return NeuralReading.humanTests
            case .lint: return NeuralReading.humanLint
            }
        }

        /// "Ran the build again" and its siblings.
        public var againTitle: String {
            switch self {
            case .build: return Localized.text("Ran the build again")
            case .test: return Localized.text("Ran the tests again")
            case .lint: return Localized.text("Ran the linter again")
            }
        }
    }

    /// A step's sentence, the raw tool name and the raw argument kept beside it.
    public struct Title: Sendable, Equatable {
        public let text: String
        /// The tool's own name: "Bash", "Read".
        public let raw: String
        /// The command, path or pattern as the agent wrote it; nil for a step with none.
        public let secondary: String?
    }

    // MARK: Titles

    /// The sentence for step `index` of `steps`: a command that follows a failed run of itself
    /// reads as a retry.
    public static func title(at index: Int, in steps: [NeuralStep]) -> Title {
        let step = steps[index]
        return Title(
            text: sentence(for: step, retry: isRetry(at: index, in: steps)),
            raw: NeuralReading.title(of: step), secondary: step.detail.isEmpty ? nil : step.detail)
    }

    /// Every step's sentence in one pass: O(steps), where `title(at:in:)` looks back each time.
    public static func titles(for steps: [NeuralStep]) -> [Title] {
        var failed = Set<String>()
        return steps.map { step in
            var retry = false
            if step.tieIsCommand, let key = step.tieKey {
                retry = failed.contains(key)
                if step.status == .failed { failed.insert(key) }
            }
            return Title(
                text: sentence(for: step, retry: retry), raw: NeuralReading.title(of: step),
                secondary: step.detail.isEmpty ? nil : step.detail)
        }
    }

    /// The sentence for a step on its own, with no way to tell a retry.
    public static func title(for step: NeuralStep) -> String {
        sentence(for: step, retry: false)
    }

    /// Whether an earlier step ran this very command and failed.
    public static func isRetry(at index: Int, in steps: [NeuralStep]) -> Bool {
        let step = steps[index]
        guard step.tieIsCommand, let key = step.tieKey else { return false }
        return steps[..<index].contains { $0.tieIsCommand && $0.tieKey == key && $0.status == .failed }
    }

    static func sentence(for step: NeuralStep, retry: Bool) -> String {
        if NeuralReading.isThought(step) || NeuralReading.isNote(step) {
            return NeuralReading.title(of: step)
        }
        let call = step.call?.call
        switch kind(of: step) {
        case .shell:
            let command = field(call, ["command"]) ?? step.detail
            let cls = classify(command)
            return retry ? againTitle(cls) : title(of: cls)
        case .fileRead:
            return named(NeuralReading.humanRead, fallback: NeuralReading.humanReadFile, step: step)
        case .fileEdit:
            guard let name = fileName(of: step) else { return NeuralReading.humanEditFile }
            if let tally = NeuralReading.tally(step.added ?? 0, step.removed ?? 0) {
                return Localized.text("Edited %1$@ (%2$@)", name, tally)
            }
            return Localized.text("Edited %@", name)
        case .fileWrite:
            return named(NeuralReading.humanWrote, fallback: NeuralReading.humanWroteFile, step: step)
        case .fileSearch:
            if let pattern = field(call, ["pattern", "query"]) ?? patternFallback(step) {
                return Localized.text("Searched for %@", clip(pattern))
            }
            if let path = field(call, ["path"]) {
                return Localized.text("Listed %@", NeuralReadoutText.split(path: path).file)
            }
            return NeuralReading.humanSearchFiles
        case .webSearch:
            guard let query = field(call, ["query"]) ?? nonEmpty(step.detail) else {
                return NeuralReading.humanSearchWeb
            }
            return Localized.text("Searched the web for %@", clip(query))
        case .webFetch:
            guard let url = field(call, ["url"]) ?? nonEmpty(step.detail) else {
                return NeuralReading.humanFetchPage
            }
            return Localized.text("Fetched %@", URL(string: url)?.host ?? clip(url))
        case .subagent:
            let words = field(call, ["description", "prompt"]) ?? nonEmpty(step.detail)
            guard let words else { return Localized.text("Asked an agent") }
            return Localized.text("Asked an agent: %@", clip(NeuralReadoutText.firstLine(words)))
        case .workflow:
            guard let name = field(call, ["name"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Ran a workflow")
            }
            return Localized.text("Ran the %@ workflow", clip(name))
        case .skill:
            guard let name = field(call, ["skill"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Used a skill")
            }
            return Localized.text("Used the %@ skill", clip(name))
        case .taskTracking:
            return TaskBoard.isBoardCall(call?.name ?? step.title)
                ? Localized.text("Updated its plan") : Localized.text("Looked at its plan")
        case .question:
            return Localized.text("Asked you a question")
        case .other:
            return Localized.text("Used %@", NeuralReading.title(of: step))
        }
    }

    /// What the step in flight is doing, as a person says it while it happens: "Running the tests".
    /// A thought or a note keeps its own words, and a command that follows a failed run of itself
    /// reads "again".
    public static func presentTitle(at index: Int, in steps: [NeuralStep]) -> String {
        presentSentence(for: steps[index], retry: isRetry(at: index, in: steps))
    }

    /// The present-tense sentence for a step on its own.
    public static func presentTitle(for step: NeuralStep) -> String {
        presentSentence(for: step, retry: false)
    }

    static func presentSentence(for step: NeuralStep, retry: Bool) -> String {
        if NeuralReading.isThought(step) || NeuralReading.isNote(step) {
            return NeuralReading.title(of: step)
        }
        let call = step.call?.call
        switch kind(of: step) {
        case .shell:
            let cls = classify(field(call, ["command"]) ?? step.detail)
            let title = presentTitle(of: cls)
            return retry ? Localized.text("%@ again", title) : title
        case .fileRead:
            return named(
                { Localized.text("Reading %@", $0) }, fallback: Localized.text("Reading a file"),
                step: step)
        case .fileEdit:
            return named(
                { Localized.text("Editing %@", $0) }, fallback: Localized.text("Editing a file"),
                step: step)
        case .fileWrite:
            return named(
                { Localized.text("Writing %@", $0) }, fallback: Localized.text("Writing a file"),
                step: step)
        case .fileSearch:
            if let pattern = field(call, ["pattern", "query"]) ?? patternFallback(step) {
                return Localized.text("Searching for %@", clip(pattern))
            }
            if let path = field(call, ["path"]) {
                return Localized.text("Listing %@", NeuralReadoutText.split(path: path).file)
            }
            return Localized.text("Searching the files")
        case .webSearch:
            guard let query = field(call, ["query"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Searching the web")
            }
            return Localized.text("Searching the web for %@", clip(query))
        case .webFetch:
            guard let url = field(call, ["url"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Fetching a page")
            }
            return Localized.text("Fetching %@", URL(string: url)?.host ?? clip(url))
        case .subagent:
            let words = field(call, ["description", "prompt"]) ?? nonEmpty(step.detail)
            guard let words else { return Localized.text("Asking an agent") }
            return Localized.text("Asking an agent: %@", clip(NeuralReadoutText.firstLine(words)))
        case .workflow:
            guard let name = field(call, ["name"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Running a workflow")
            }
            return Localized.text("Running the %@ workflow", clip(name))
        case .skill:
            guard let name = field(call, ["skill"]) ?? nonEmpty(step.detail) else {
                return Localized.text("Using a skill")
            }
            return Localized.text("Using the %@ skill", clip(name))
        case .taskTracking:
            return TaskBoard.isBoardCall(call?.name ?? step.title)
                ? Localized.text("Updating its plan") : Localized.text("Looking at its plan")
        case .question:
            return Localized.text("Asking you a question")
        case .other:
            return Localized.text("Using %@", NeuralReading.title(of: step))
        }
    }

    /// A command class in the present tense.
    public static func presentTitle(of cls: CommandClass) -> String {
        switch cls {
        case .build: return Localized.text("Building the project")
        case .test: return Localized.text("Running the tests")
        case .lint: return Localized.text("Running the linter")
        case .gitStatus: return Localized.text("Checking git status")
        case .gitDiff: return Localized.text("Looking at the diff")
        case .gitCommit: return Localized.text("Committing")
        case .gitPush: return Localized.text("Pushing")
        case .gitOther(let sub): return Localized.text("Running git %@", sub)
        case .install(let package):
            return package.map { Localized.text("Installing %@", $0) } ?? Localized.text("Installing")
        case .search: return Localized.text("Searching the files")
        case .look: return Localized.text("Looking at files")
        case .fetch: return Localized.text("Fetching a page")
        case .media(let program), .script(let program), .other(let program):
            return Localized.text("Running %@", program)
        case .none: return Localized.text("Running a command")
        }
    }

    private static func kind(of step: NeuralStep) -> ToolCallSummary.Kind {
        if let call = step.call?.call { return call.cachedKind }
        return ToolKindMemo.kind(ofToolNamed: step.title)
    }

    private static func field(_ call: ToolCall?, _ keys: [String]) -> String? {
        guard let input = call?.input else { return nil }
        for key in keys {
            if let value = input[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    private static func nonEmpty(_ text: String) -> String? { text.isEmpty ? nil : text }

    private static func patternFallback(_ step: NeuralStep) -> String? {
        guard step.call == nil, !step.detail.isEmpty else { return nil }
        return step.detail.split(separator: " ", maxSplits: 1).first.map(String.init)
    }

    private static func fileName(of step: NeuralStep) -> String? {
        let path =
            field(
                step.call?.call, ["file_path", "filePath", "path", "notebook_path"])
            ?? step.tieKey ?? nonEmpty(step.detail)
        guard let path else { return nil }
        let name = NeuralReadoutText.split(path: path).file
        return name.isEmpty ? nil : name
    }

    private static func named(_ make: (String) -> String, fallback: String, step: NeuralStep) -> String {
        fileName(of: step).map(make) ?? fallback
    }

    private static func clip(_ text: String) -> String {
        let one = NeuralReadoutText.oneLine(text, limit: 120)
        return NeuralReadoutText.capped(one, limit: 48).text
    }

    // MARK: Commands

    /// The sentence for a kind of command.
    public static func title(of cls: CommandClass) -> String {
        switch cls {
        case .build: return NeuralReading.humanBuilt
        case .test: return NeuralReading.humanTests
        case .lint: return NeuralReading.humanLint
        case .gitStatus: return Localized.text("Checked git status")
        case .gitDiff: return Localized.text("Looked at the diff")
        case .gitCommit: return Localized.text("Committed")
        case .gitPush: return Localized.text("Pushed")
        case .gitOther(let sub): return Localized.text("Ran git %@", sub)
        case .install(let package):
            return package.map { Localized.text("Installed %@", $0) } ?? Localized.text("Installed")
        case .search: return NeuralReading.humanSearchFiles
        case .look: return Localized.text("Looked at files")
        case .fetch: return NeuralReading.humanFetchPage
        case .media(let program), .script(let program), .other(let program):
            return Localized.text("Ran %@", program)
        case .none: return Localized.text("Ran a command")
        }
    }

    /// The same for a command that runs again after a failed run.
    public static func againTitle(_ cls: CommandClass) -> String {
        if let check = cls.checkKind { return check.againTitle }
        return Localized.text("%@ again", title(of: cls))
    }

    /// The class of a shell command: its first meaningful program, past env assignments, `sudo`,
    /// `time`, `cd x &&` and the like, and past everything after a pipe.
    public static func classify(_ command: String) -> CommandClass {
        for words in heads(of: command) {
            let words = strippedPrefixes(words)
            guard let first = words.first else { continue }
            let program = baseName(first)
            if skipped.contains(program) { continue }
            return classify(program: program, arguments: Array(words.dropFirst()))
        }
        return .none
    }

    /// The first meaningful program of a command, as written: "swift", "foo.sh".
    public static func program(of command: String) -> String? {
        switch classify(command) {
        case .media(let name), .script(let name), .other(let name): return name
        case .none: return nil
        case .build, .test, .lint, .gitStatus, .gitDiff, .gitCommit, .gitPush, .gitOther, .install,
            .search, .look, .fetch:
            for words in heads(of: command) {
                guard let first = strippedPrefixes(words).first else { continue }
                let program = baseName(first)
                if !skipped.contains(program) { return program }
            }
            return nil
        }
    }

    private static let skipped: Set<String> = [
        "cd", "pushd", "popd", "export", "set", "unset", "source", ".", "alias", "ulimit", "umask",
        "true", ":", "shopt", "trap",
    ]

    private static let wrappers: Set<String> = [
        "sudo", "time", "nice", "nohup", "command", "exec", "env", "doas", "caffeinate", "stdbuf",
        "ionice", "chrt", "setsid",
    ]

    private static func baseName(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()`{}"))
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            && !(word.first?.isNumber ?? false)
    }

    /// Drops env assignments and wrapper programs (and the options they take) from the front.
    private static func strippedPrefixes(_ words: [String]) -> [String] {
        var rest = words[...]
        while let first = rest.first {
            if isAssignment(first) {
                rest = rest.dropFirst()
                continue
            }
            let name = baseName(first)
            guard wrappers.contains(name) else { break }
            rest = rest.dropFirst()
            while let next = rest.first, next.hasPrefix("-") || isAssignment(next) {
                rest = rest.dropFirst()
                if name == "sudo" || name == "nice", ["-u", "-n", "-g"].contains(next), !rest.isEmpty {
                    rest = rest.dropFirst()
                }
            }
        }
        if let first = rest.first, baseName(first) == "timeout" {
            rest = rest.dropFirst()
            while let next = rest.first, next.hasPrefix("-") { rest = rest.dropFirst() }
            if !rest.isEmpty { rest = rest.dropFirst() }
            return strippedPrefixes(Array(rest))
        }
        return Array(rest)
    }

    /// The first command of every pipeline of a command line, as words: `a && b | c; d` has the
    /// heads `a`, `b` and `d`. Quotes keep their words whole and group operators are not read
    /// inside them.
    static func heads(of command: String) -> [[String]] {
        var out: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var piped = false
        var escaped = false
        var inWord = false

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endCommand(thenPiped: Bool) {
            endWord()
            if !words.isEmpty, !piped { out.append(words) }
            words = []
            piped = thenPiped
        }
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if escaped {
                word.append(c)
                inWord = true
                escaped = false
            } else if let open = quote {
                if c == open { quote = nil } else { word.append(c) }
                inWord = true
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" || c == "'" {
                quote = c
                inWord = true
            } else if c == "\n" || c == ";" {
                endCommand(thenPiped: false)
            } else if c == "&" {
                if index + 1 < characters.count, characters[index + 1] == "&" {
                    index += 1
                    endCommand(thenPiped: false)
                } else if word.hasSuffix(">") || (index > 0 && characters[index - 1] == ">") {
                    word.append(c)
                    inWord = true
                } else {
                    endCommand(thenPiped: false)
                }
            } else if c == "|" {
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    index += 1
                    endCommand(thenPiped: false)
                } else {
                    endCommand(thenPiped: true)
                }
            } else if c == " " || c == "\t" {
                endWord()
            } else if c == "#", !inWord {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            } else {
                word.append(c)
                inWord = true
            }
            index += 1
        }
        endCommand(thenPiped: false)
        return out
    }

    private static func firstArgument(_ arguments: [String]) -> String? {
        arguments.first { !$0.hasPrefix("-") }
    }

    private static let interpreters: Set<String> = [
        "bash", "sh", "zsh", "fish", "dash", "python", "python3", "python2", "node", "deno", "bun",
        "ruby", "perl", "php", "lua", "tsx", "ts-node",
    ]

    private static func classify(program: String, arguments: [String]) -> CommandClass {
        let lowered = program.lowercased()
        let first = firstArgument(arguments)?.lowercased()
        let scriptSuffixes = [".sh", ".bash", ".zsh", ".py", ".rb", ".js", ".mjs", ".ts", ".pl", ".php"]
        if scriptSuffixes.contains(where: { lowered.hasSuffix($0) }) { return .script(program) }
        switch lowered {
        case "swift":
            switch first {
            case "build": return .build
            case "test": return .test
            default: return .other(program)
            }
        case "xcodebuild":
            let all = arguments.map { $0.lowercased() }
            return all.contains("test") || all.contains("test-without-building") ? .test : .build
        case "cargo":
            switch first {
            case "build", "check", "bench": return .build
            case "test", "nextest": return .test
            case "clippy": return .lint
            case "install": return .install(arguments.dropFirst().first { !$0.hasPrefix("-") })
            default: return .other(program)
            }
        case "make", "gmake", "ninja", "cmake", "bazel":
            switch first {
            case "test", "check", "tests": return .test
            case "lint": return .lint
            case "install": return .install(nil)
            case "clean", "distclean": return .other(program)
            default: return .build
            }
        case "npm", "yarn", "pnpm", "bun-run", "npx":
            return packageManager(program: program, arguments: arguments)
        case "go":
            switch first {
            case "build": return .build
            case "test": return .test
            case "vet": return .lint
            case "install": return .install(arguments.dropFirst().first { !$0.hasPrefix("-") })
            default: return .other(program)
            }
        case "gradle", "gradlew", "mvn", "mvnw":
            if arguments.contains(where: { $0.lowercased().contains("test") }) { return .test }
            return .build
        case "tsc", "webpack", "vite", "esbuild", "rollup":
            return .build
        case "pytest", "py.test", "jest", "vitest", "mocha", "ctest", "rspec", "phpunit", "tox",
            "nosetests":
            return .test
        case "swiftlint", "eslint", "ruff", "flake8", "pylint", "shellcheck", "rubocop",
            "golangci-lint", "mypy", "stylelint", "swift-format", "luacheck":
            return .lint
        case "prettier":
            return .lint
        case "git":
            return git(arguments: arguments, program: program)
        case "brew", "apt", "apt-get", "dnf", "yum", "pip", "pip3", "pipx", "gem", "conda", "mamba",
            "flatpak", "snap", "pacman", "yay", "paru", "zypper", "apk", "uv":
            return installer(program: lowered, arguments: arguments) ?? .other(program)
        case "rg", "grep", "egrep", "fgrep", "ag", "ack", "find", "fd", "fdfind", "locate", "mdfind":
            return .search
        case "ls", "ll", "la", "cat", "bat", "head", "tail", "wc", "less", "more", "tree", "stat",
            "file", "du", "df", "pwd", "nl", "readlink", "realpath", "basename", "dirname":
            return .look
        case "sed":
            return arguments.contains { $0 == "-n" || $0.hasPrefix("-n") && !$0.hasPrefix("-ne") }
                ? .look : .other(program)
        case "curl", "wget", "http", "https", "xh":
            return .fetch
        case "ffmpeg", "ffprobe", "ffplay":
            return .media(program)
        default:
            if interpreters.contains(lowered) { return interpreter(program: program, arguments: arguments) }
            return .other(program)
        }
    }

    private static func packageManager(program: String, arguments: [String]) -> CommandClass {
        let first = firstArgument(arguments)?.lowercased()
        switch first {
        case "test", "t", "tests": return .test
        case "build": return .build
        case "lint": return .lint
        case "install", "i", "add", "ci":
            return .install(arguments.dropFirst().first { !$0.hasPrefix("-") && $0 != first })
        case "run", "run-script":
            let script = arguments.drop { $0 != first }.dropFirst().first { !$0.hasPrefix("-") }?.lowercased() ?? ""
            if script.contains("build") { return .build }
            if script.contains("test") { return .test }
            if script.contains("lint") || script.contains("check") { return .lint }
            return .other(program)
        default:
            return .other(program)
        }
    }

    private static func git(arguments: [String], program: String) -> CommandClass {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "-C" || word == "-c" || word == "--git-dir" || word == "--work-tree" {
                index += 2
            } else if word.hasPrefix("-") {
                index += 1
            } else {
                break
            }
        }
        guard index < arguments.count else { return .other(program) }
        let sub = arguments[index]
        switch sub.lowercased() {
        case "status": return .gitStatus
        case "diff", "show": return .gitDiff
        case "commit": return .gitCommit
        case "push": return .gitPush
        default: return .gitOther(sub)
        }
    }

    private static func installer(program: String, arguments: [String]) -> CommandClass? {
        let words = arguments.filter { !$0.hasPrefix("-") }
        let sub = words.first?.lowercased() ?? ""
        let installs: Bool
        switch program {
        case "pacman": installs = arguments.contains { $0.hasPrefix("-S") && !$0.hasPrefix("-Ss") }
        case "yay", "paru": installs = arguments.isEmpty || arguments.contains { $0.hasPrefix("-S") }
        case "uv": installs = sub == "add" || (sub == "pip" && words.dropFirst().first == "install")
        default: installs = ["install", "add", "i"].contains(sub)
        }
        guard installs else { return nil }
        let package = words.dropFirst(program == "uv" && sub == "pip" ? 2 : 1).first
        return .install(program == "pacman" ? words.first : package)
    }

    private static func interpreter(program: String, arguments: [String]) -> CommandClass {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word == "-m", index + 1 < arguments.count {
                let module = arguments[index + 1].lowercased()
                if module == "pytest" { return .test }
                if module == "unittest" { return .test }
                if ["ruff", "flake8", "pylint", "mypy"].contains(module) { return .lint }
                return .other(arguments[index + 1])
            }
            if word == "-c" || word == "-e" { return .other(program) }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            return .script(baseName(word))
        }
        return .other(program)
    }
}

extension NeuralReading {
    public static var humanBuilt: String { Localized.text("Built the project") }
    public static var humanTests: String { Localized.text("Ran the tests") }
    public static var humanLint: String { Localized.text("Ran the linter") }
    public static var humanSearchFiles: String { Localized.text("Searched the files") }
    public static var humanFetchPage: String { Localized.text("Fetched a page") }
    public static var humanSearchWeb: String { Localized.text("Searched the web") }
    public static var humanReadFile: String { Localized.text("Read a file") }
    public static var humanEditFile: String { Localized.text("Edited a file") }
    public static var humanWroteFile: String { Localized.text("Wrote a file") }

    static func humanRead(_ name: String) -> String { Localized.text("Read %@", name) }
    static func humanWrote(_ name: String) -> String { Localized.text("Wrote %@", name) }

    /// A step's plain sentence: "Built the project". The tool's own name is `title(of:)`.
    public static func humanTitle(of step: NeuralStep) -> String { NeuralHuman.title(for: step) }
}
