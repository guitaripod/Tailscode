import Foundation

/// A shell command read for what it does, not for what it says: the first thing each command in
/// the line is about, in order, with the wrappers (`sudo`, `time`, `FOO=1`, `cd x &&`) taken off.
struct ShellReading {
    enum Action: Equatable {
        case test, build, install, run
        case gitStatus, gitDiff, gitLog, gitCommit, gitPush, gitForcePush, gitPull, gitDiscard, gitOther, github
        case listFiles, findFiles, readFile, search, textTools
        case makeFolder, touch, remove, clearBuild, copy, move, permissions
        case download, downloadAndRun, remote, sync
        case stopProgram, service, containers, wait, processes
        case script, lint, format, print, checkInstalled, checkSystem, archive, open
        case other
    }

    let actions: [Action]
    let isElevated: Bool

    private static let buildFolders: Set<String> = [
        "build", ".build", "dist", "out", "target", "deriveddata", "derived-data", "node_modules", ".next",
        "__pycache__", ".cache", "coverage", ".swiftpm", "cache", "tmp",
    ]

    private static let interpreters: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "python", "python3", "perl", "ruby", "node", "php", "lua",
    ]

    private static let wrappers: Set<String> = [
        "sudo", "doas", "time", "nohup", "nice", "ionice", "env", "exec", "builtin", "stdbuf",
        "caffeinate", "xcrun", "setsid", "unbuffer", "timeout", "chronic",
    ]

    init(_ raw: String) {
        var found: [Action] = []
        var elevated = false
        for command in Self.commands(in: raw).prefix(8) {
            let (action, root) = Self.read(command, depth: 0)
            elevated = elevated || root
            found.append(contentsOf: action)
        }
        var settled: [Action] = []
        for action in found where settled.last != action { settled.append(action) }
        actions = settled
        isElevated = elevated
    }

    var isKnown: Bool { actions.contains { $0 != .other } }

    func sentence(_ tense: AgentPlain.Tense) -> String? {
        guard isKnown else { return nil }
        let phrases = actions.map { Self.phrase($0, tense) }
        let shown = phrases.prefix(2).joined(separator: " → ")
        return phrases.count > 2 ? shown + " → …" : shown
    }

    static func commands(in raw: String) -> [[[String]]] {
        var commands: [[[String]]] = []
        var stages: [[String]] = []
        var tokens: [String] = []
        var word = ""
        var hasWord = false
        var quote: Character?
        var escaped = false
        let characters = Array(raw)
        var index = 0

        func endWord() {
            if hasWord { tokens.append(word) }
            word = ""
            hasWord = false
        }
        func endStage() {
            endWord()
            if !tokens.isEmpty { stages.append(tokens) }
            tokens = []
        }
        func endCommand() {
            endStage()
            if !stages.isEmpty { commands.append(stages) }
            stages = []
        }

        while index < characters.count {
            let character = characters[index]
            index += 1
            if escaped {
                word.append(character)
                hasWord = true
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                hasWord = true
            } else if character == "\n" || character == ";" {
                endCommand()
            } else if character == "&" || character == "|" {
                let doubled = index < characters.count && characters[index] == character
                if doubled { index += 1 }
                if character == "|" && !doubled { endStage() } else if doubled { endCommand() } else { endWord() }
            } else if character == " " || character == "\t" {
                endWord()
            } else {
                word.append(character)
                hasWord = true
            }
        }
        endCommand()
        return commands
    }

    private static func read(_ stages: [[String]], depth: Int) -> ([Action], Bool) {
        guard var tokens = stages.first else { return ([], false) }
        var elevated = false
        strip(&tokens, elevated: &elevated)
        guard let head = tokens.first else { return ([], elevated) }
        let exe = basename(head)
        let later = stages.dropFirst().compactMap { stage -> String? in
            var rest = stage
            var ignored = false
            strip(&rest, elevated: &ignored)
            return rest.first.map(basename)
        }
        if later.contains(where: { interpreters.contains($0) }) {
            return ([exe == "curl" || exe == "wget" ? .downloadAndRun : .other], elevated)
        }
        if ["sh", "bash", "zsh", "dash"].contains(exe), depth == 0,
            let flag = tokens.firstIndex(of: "-c") ?? tokens.firstIndex(of: "-lc"),
            tokens.indices.contains(flag + 1)
        {
            var inner: [Action] = []
            for command in commands(in: tokens[flag + 1]).prefix(8) {
                let (action, root) = read(command, depth: depth + 1)
                elevated = elevated || root
                inner.append(contentsOf: action)
            }
            return (inner, elevated)
        }
        return (action(for: tokens).map { [$0] } ?? [], elevated)
    }

    private static func strip(_ tokens: inout [String], elevated: inout Bool) {
        while let head = tokens.first {
            let name = basename(head)
            if isAssignment(head) {
                tokens.removeFirst()
            } else if wrappers.contains(name) {
                tokens.removeFirst()
                if name == "sudo" || name == "doas" { elevated = true }
                while let flag = tokens.first, flag.hasPrefix("-") {
                    tokens.removeFirst()
                    if ["-u", "-g", "-n", "-k", "-s", "-c"].contains(flag), !tokens.isEmpty { tokens.removeFirst() }
                }
                if name == "timeout", let duration = tokens.first,
                    duration.first?.isNumber == true
                {
                    tokens.removeFirst()
                }
            } else {
                break
            }
        }
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        return token[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func basename(_ token: String) -> String {
        (token.split(separator: "/").last.map(String.init) ?? token).lowercased()
    }

    private static func firstArgument(_ args: [String], skipping valued: Set<String> = []) -> String? {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if valued.contains(arg) {
                index += 2
            } else if arg.hasPrefix("-") {
                index += 1
            } else {
                return arg.lowercased()
            }
        }
        return nil
    }

    private static func action(for tokens: [String]) -> Action? {
        let exe = basename(tokens[0])
        let args = Array(tokens.dropFirst())
        let lowered = args.map { $0.lowercased() }
        let sub = firstArgument(args)
        switch exe {
        case "cd", "pushd", "popd", "export", "source", ".", "set", "unset", "alias", "true", "false", ":",
            "exit", "return", "wait", "local", "declare", "trap", "umask", "ulimit", "hash", "[", "[[", "test":
            return nil
        case "swift":
            switch sub {
            case "test": return .test
            case "build": return .build
            case "run": return .run
            case "package": return .install
            case "format": return .format
            default: return .script
            }
        case "xcodebuild":
            if lowered.contains("test") { return .test }
            return lowered.contains("clean") ? .clearBuild : .build
        case "cargo":
            switch sub {
            case "test", "nextest": return .test
            case "run": return .run
            case "add", "install", "update", "fetch", "remove": return .install
            case "clippy": return .lint
            case "fmt": return .format
            default: return .build
            }
        case "npm", "pnpm", "yarn", "bun":
            return packageScript(sub, lowered)
        case "pytest", "jest", "vitest", "rspec", "phpunit", "mocha", "tox", "nose2", "ctest":
            return .test
        case "go":
            switch sub {
            case "test": return .test
            case "run": return .run
            case "get", "mod", "install": return .install
            case "vet": return .lint
            case "fmt": return .format
            default: return .build
            }
        case "make", "gmake", "ninja":
            switch sub {
            case "test", "check": return .test
            case "install": return .install
            case "clean", "distclean": return .clearBuild
            default: return .build
            }
        case "cmake", "gradle", "gradlew", "mvn", "bazel", "tsc", "webpack", "vite", "esbuild", "rollup", "meson", "msbuild", "dotnet":
            if lowered.contains("test") { return .test }
            return .build
        case "pip", "pip3", "pipx", "uv", "poetry", "brew", "apt", "apt-get", "dnf", "yum", "pacman", "yay",
            "paru", "snap", "flatpak", "gem", "bundle", "composer", "conda", "mamba", "nix-env", "opam", "cabal", "stack":
            let looking: Set<String> = ["list", "info", "search", "show", "-q", "-ss", "-qi", "-qs", "outdated", "freeze"]
            if lowered.contains(where: { looking.contains($0) }) { return .checkInstalled }
            return .install
        case "python", "python3", "python2", "node", "ruby", "perl", "php", "deno", "lua", "tclsh", "swiftc":
            if let module = lowered.firstIndex(of: "-m"), lowered.indices.contains(module + 1) {
                switch lowered[module + 1] {
                case "pytest", "unittest", "nose": return .test
                case "pip": return .install
                default: return .script
                }
            }
            return lowered.contains("--test") ? .test : .script
        case "bash", "sh", "zsh", "dash", "fish":
            return .script
        case "git":
            return git(args, lowered)
        case "gh", "glab", "hub":
            return .github
        case "ls", "tree", "exa", "eza", "dir", "lsd", "stat", "file", "pwd", "readlink", "realpath", "basename", "dirname":
            return .listFiles
        case "find", "fd", "locate", "mdfind", "plocate":
            return .findFiles
        case "cat", "head", "tail", "less", "more", "bat", "nl", "view", "xxd", "hexdump", "strings":
            return .readFile
        case "grep", "rg", "ag", "ack", "zgrep", "egrep", "fgrep", "ugrep":
            return .search
        case "sed", "awk", "sort", "uniq", "cut", "tr", "jq", "yq", "xargs", "tee", "column", "wc", "paste", "fold", "rev", "diff", "cmp", "comm":
            return .textTools
        case "mkdir": return .makeFolder
        case "touch": return .touch
        case "rm", "rmdir", "unlink", "trash", "shred":
            let targets = args.filter { !$0.hasPrefix("-") }.map(basename)
            let isBuild = !targets.isEmpty && targets.allSatisfy { buildFolders.contains($0) || $0.hasPrefix("build") }
            return isBuild ? .clearBuild : .remove
        case "cp", "install", "ditto": return .copy
        case "mv", "rename": return .move
        case "chmod", "chown", "chgrp", "chattr", "setfacl": return .permissions
        case "curl", "wget", "http", "https", "xh", "aria2c": return .download
        case "ssh", "mosh", "telnet", "nc", "ncat", "ping", "traceroute", "dig", "nslookup": return .remote
        case "scp", "rsync", "sftp", "rclone": return .sync
        case "kill", "pkill", "killall", "xkill", "skill": return .stopProgram
        case "systemctl", "service", "launchctl", "rc-service", "journalctl", "loginctl": return .service
        case "docker", "podman", "kubectl", "docker-compose", "helm", "minikube", "kind", "nerdctl", "lima", "colima": return .containers
        case "sleep": return .wait
        case "ps", "top", "htop", "btop", "pgrep", "lsof", "ss", "netstat", "pidof", "jobs", "pstree": return .processes
        case "swiftlint", "eslint", "ruff", "flake8", "pylint", "mypy", "shellcheck", "golangci-lint", "hadolint", "rubocop", "pyright", "tflint", "stylelint":
            return .lint
        case "swiftformat", "prettier", "black", "gofmt", "rustfmt", "clang-format", "isort", "autopep8", "shfmt", "stylua", "yapf":
            return .format
        case "echo", "printf": return .print
        case "which", "type", "whereis", "command", "apropos", "man", "help", "tldr": return .checkInstalled
        case "uname", "whoami", "hostname", "uptime", "free", "date", "env", "printenv", "id", "lscpu", "lsblk", "sw_vers",
            "nproc", "arch", "df", "du", "vmstat", "iostat", "sysctl", "nvidia-smi", "lspci", "lsusb", "dmesg", "w", "who":
            return .checkSystem
        case "tar", "zip", "unzip", "gzip", "gunzip", "bzip2", "xz", "7z", "unrar", "zcat": return .archive
        case "open", "xdg-open", "code", "vim", "nvim", "nano", "emacs": return .open
        default: return .other
        }
    }

    private static func packageScript(_ sub: String?, _ args: [String]) -> Action {
        switch sub {
        case "test", "t": return .test
        case "install", "i", "ci", "add", "update", "upgrade", "remove", "uninstall", "rm": return .install
        case "build": return .build
        case "start", "dev", "serve", "preview": return .run
        case "lint": return .lint
        case "format", "fmt": return .format
        case "run", "run-script", "exec", "x":
            guard let script = args.drop(while: { $0.hasPrefix("-") }).dropFirst().first(where: { !$0.hasPrefix("-") }) else {
                return .run
            }
            if script.hasPrefix("test") { return .test }
            if script.hasPrefix("build") || script == "compile" { return .build }
            if script.hasPrefix("lint") { return .lint }
            if script.hasPrefix("format") || script.hasPrefix("fmt") || script.hasPrefix("prettier") { return .format }
            return .run
        default:
            return .run
        }
    }

    private static func git(_ args: [String], _ lowered: [String]) -> Action {
        let sub = firstArgument(args, skipping: ["-C", "-c", "--git-dir", "--work-tree"])
        switch sub {
        case "status": return .gitStatus
        case "diff", "show", "difftool": return .gitDiff
        case "log", "blame", "shortlog", "reflog", "describe", "rev-parse", "rev-list": return .gitLog
        case "commit": return .gitCommit
        case "push":
            return lowered.contains("--force") || lowered.contains("-f") || lowered.contains("--force-with-lease")
                ? .gitForcePush : .gitPush
        case "pull", "fetch", "clone": return .gitPull
        case "reset": return lowered.contains("--hard") ? .gitDiscard : .gitOther
        case "clean": return lowered.contains(where: { $0.hasPrefix("-") && $0.contains("f") }) ? .gitDiscard : .gitOther
        default: return .gitOther
        }
    }

    private static func phrase(_ action: Action, _ tense: AgentPlain.Tense) -> String {
        let running = tense == .running
        switch action {
        case .test: return running ? Localized.text("Running the tests") : Localized.text("Ran the tests")
        case .build: return running ? Localized.text("Building the project") : Localized.text("Built the project")
        case .install:
            return running ? Localized.text("Installing what it needs") : Localized.text("Installed what it needed")
        case .run: return running ? Localized.text("Starting the app") : Localized.text("Started the app")
        case .gitStatus: return running ? Localized.text("Checking what changed") : Localized.text("Checked what changed")
        case .gitDiff: return running ? Localized.text("Looking at the changes") : Localized.text("Looked at the changes")
        case .gitLog: return running ? Localized.text("Reading the history") : Localized.text("Read the history")
        case .gitCommit: return running ? Localized.text("Saving the changes") : Localized.text("Saved the changes")
        case .gitPush: return running ? Localized.text("Uploading the changes") : Localized.text("Uploaded the changes")
        case .gitForcePush:
            return running ? Localized.text("Force-uploading the changes") : Localized.text("Force-uploaded the changes")
        case .gitPull:
            return running ? Localized.text("Getting the latest changes") : Localized.text("Got the latest changes")
        case .gitDiscard:
            return running ? Localized.text("Throwing away local changes") : Localized.text("Threw away local changes")
        case .gitOther: return running ? Localized.text("Working with git") : Localized.text("Worked with git")
        case .github: return running ? Localized.text("Using GitHub") : Localized.text("Used GitHub")
        case .listFiles:
            return running ? Localized.text("Looking around the folder") : Localized.text("Looked around the folder")
        case .findFiles: return running ? Localized.text("Looking for files") : Localized.text("Looked for files")
        case .readFile: return running ? Localized.text("Reading a file") : Localized.text("Read a file")
        case .search: return running ? Localized.text("Searching the code") : Localized.text("Searched the code")
        case .textTools: return running ? Localized.text("Sorting through text") : Localized.text("Sorted through text")
        case .makeFolder: return running ? Localized.text("Creating a folder") : Localized.text("Created a folder")
        case .touch: return running ? Localized.text("Creating an empty file") : Localized.text("Created an empty file")
        case .remove: return running ? Localized.text("Deleting files") : Localized.text("Deleted files")
        case .clearBuild:
            return running ? Localized.text("Clearing the build folder") : Localized.text("Cleared the build folder")
        case .copy: return running ? Localized.text("Copying files") : Localized.text("Copied files")
        case .move: return running ? Localized.text("Moving files") : Localized.text("Moved files")
        case .permissions:
            return running ? Localized.text("Changing file permissions") : Localized.text("Changed file permissions")
        case .download:
            return running ? Localized.text("Fetching something from the web") : Localized.text("Fetched something from the web")
        case .downloadAndRun:
            return running
                ? Localized.text("Downloading a script and running it")
                : Localized.text("Downloaded a script and ran it")
        case .remote:
            return running
                ? Localized.text("Talking to another machine") : Localized.text("Talked to another machine")
        case .sync:
            return running ? Localized.text("Syncing files between machines") : Localized.text("Synced files between machines")
        case .stopProgram: return running ? Localized.text("Stopping a program") : Localized.text("Stopped a program")
        case .service:
            return running ? Localized.text("Managing a background service") : Localized.text("Managed a background service")
        case .containers: return running ? Localized.text("Working with containers") : Localized.text("Worked with containers")
        case .wait: return running ? Localized.text("Waiting a moment") : Localized.text("Waited a moment")
        case .processes:
            return running ? Localized.text("Checking what is running") : Localized.text("Checked what was running")
        case .script: return running ? Localized.text("Running a script") : Localized.text("Ran a script")
        case .lint: return running ? Localized.text("Checking the code for mistakes") : Localized.text("Checked the code for mistakes")
        case .format: return running ? Localized.text("Tidying the code format") : Localized.text("Tidied the code format")
        case .print: return running ? Localized.text("Printing a message") : Localized.text("Printed a message")
        case .checkInstalled:
            return running ? Localized.text("Checking what is installed") : Localized.text("Checked what was installed")
        case .checkSystem: return running ? Localized.text("Checking the system") : Localized.text("Checked the system")
        case .archive:
            return running ? Localized.text("Packing or unpacking files") : Localized.text("Packed or unpacked files")
        case .open: return running ? Localized.text("Opening something") : Localized.text("Opened something")
        case .other: return running ? Localized.text("Running a command") : Localized.text("Ran a command")
        }
    }
}
