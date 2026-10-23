import Foundation

/// The grammar of one language family, as data rather than code. Nearly every language an agent
/// writes is a comment style, a string style, a keyword list and a couple of habits, so they are
/// spelled out in a table and lexed by one scanner — a new language is a table entry, not a parser.
struct SyntaxGrammar: Sendable {
    struct Block: Sendable {
        let open: String
        let close: String
        let nests: Bool

        init(_ open: String, _ close: String, nests: Bool = false) {
            self.open = open
            self.close = close
            self.nests = nests
        }
    }

    /// A hole in a string where code goes: `\(name)` in Swift, `${…}` in a shell or a template
    /// literal, a bare `$VAR` where the shell needs no braces. A `close` of nil means the hole ends
    /// where the identifier does.
    struct Interpolation: Sendable {
        let open: String
        let close: String?

        init(_ open: String, _ close: String? = nil) {
            self.open = open
            self.close = close
        }
    }

    struct Quote: Sendable {
        let open: String
        let close: String
        let escape: Character?
        let multiline: Bool
        /// Only the quote styles that actually interpolate carry these, which is why a shell's
        /// single quotes leave `$HOME` alone and its double quotes do not.
        let interpolations: [Interpolation]

        init(
            _ open: String, _ close: String? = nil, escape: Character? = "\\",
            multiline: Bool = false, interpolations: [Interpolation] = []
        ) {
            self.open = open
            self.close = close ?? open
            self.escape = escape
            self.multiline = multiline
            self.interpolations = interpolations
        }
    }

    var lineComments: [String] = []
    var blocks: [Block] = []
    var quotes: [Quote] = []
    var keywords: Set<String> = []
    var builtins: Set<String> = []
    var caseInsensitive = false
    var capitalizedIsType = false
    var callIsFunction = true
    /// `@decorator`, `#[derive]`, `#include` — a mark on the code rather than code.
    var attributeSigils: [String] = []
    /// `$VAR` and `${VAR}` in the shells, `$name` in PHP.
    var dollarVariables = false
    var identifierExtras: Set<Character> = ["_"]
}

/// Which of the six passes a tag is lexed by. Most languages are `general`; the rest earn a pass
/// because their meaning is not carried by keywords — a diff's meaning is in its first column, a
/// config file's in what sits left of the colon.
enum SyntaxDialect: Sendable {
    case general(SyntaxGrammar)
    case diff
    case markup
    case style
    case keyed(KeyedFlavour)
    case markdown
}

/// The shape of a key/value file: what opens a comment, and whether `[section]` headers exist.
struct KeyedFlavour: Sendable {
    let lineComments: [String]
    let sections: Bool
    let quotesValues: Bool
    /// JSON has no bare keys, so a quoted run before a colon is the key rather than a string.
    let quotedKeys: Bool
}

extension SyntaxHighlighter {
    /// What a fence tag is called once resolved, for the header a code block wears. Only the tags
    /// whose spelling differs from the name a reader expects need an entry.
    static let canonicalNames: [String: String] = [
        "py": "python", "rb": "ruby", "rs": "rust", "js": "javascript", "ts": "typescript",
        "kt": "kotlin", "yml": "yaml", "sh": "bash", "zsh": "bash", "shell": "bash",
        "console": "bash", "objc": "objective-c", "cpp": "c++", "cc": "c++", "cs": "c#",
        "csharp": "c#", "md": "markdown", "patch": "diff", "jl": "julia", "ex": "elixir",
        "exs": "elixir", "hs": "haskell", "pl": "perl", "ps1": "powershell", "tf": "terraform",
    ]

    static let dialects: [String: SyntaxDialect] = {
        var table: [String: SyntaxDialect] = [:]
        func register(_ tags: [String], _ dialect: SyntaxDialect) {
            for tag in tags { table[tag] = dialect }
        }

        register(["swift"], .general(Grammars.swift))
        register(["rust", "rs"], .general(Grammars.rust))
        register(
            ["javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx"],
            .general(Grammars.javascript))
        register(["python", "py"], .general(Grammars.python))
        register(["go", "golang"], .general(Grammars.go))
        register(["c", "h"], .general(Grammars.c))
        register(["cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "m", "mm", "metal"],
            .general(Grammars.cpp))
        register(["java"], .general(Grammars.java))
        register(["kotlin", "kt", "kts"], .general(Grammars.kotlin))
        register(["cs", "csharp"], .general(Grammars.csharp))
        register(["ruby", "rb"], .general(Grammars.ruby))
        register(
            ["bash", "sh", "zsh", "shell", "console", "fish", "shellsession"],
            .general(Grammars.shell))
        register(["php"], .general(Grammars.php))
        register(["lua"], .general(Grammars.lua))
        register(["sql", "postgres", "psql", "mysql", "sqlite"], .general(Grammars.sql))
        register(["haskell", "hs"], .general(Grammars.haskell))
        register(["elixir", "ex", "exs"], .general(Grammars.elixir))
        register(["zig"], .general(Grammars.zig))
        register(["dart"], .general(Grammars.dart))
        register(["scala"], .general(Grammars.scala))
        register(["perl", "pl"], .general(Grammars.perl))
        register(["r"], .general(Grammars.r))
        register(["julia", "jl"], .general(Grammars.julia))
        register(["nix"], .general(Grammars.nix))
        register(["lisp", "clojure", "clj", "cljs", "scheme", "elisp"], .general(Grammars.lisp))
        register(["powershell", "ps1", "pwsh"], .general(Grammars.powershell))
        register(["groovy", "gradle"], .general(Grammars.java))
        register(["terraform", "tf", "hcl"], .general(Grammars.hcl))
        register(["dockerfile", "docker"], .general(Grammars.dockerfile))
        register(["make", "makefile", "cmake"], .general(Grammars.make))
        register(["vim", "viml"], .general(Grammars.vim))

        register(["diff", "patch"], .diff)
        register(["html", "xml", "svg", "xhtml", "vue", "svelte", "plist"], .markup)
        register(["css", "scss", "sass", "less"], .style)
        register(["markdown", "md", "mdx"], .markdown)

        register(
            ["json", "json5", "jsonc", "geojson"],
            .keyed(KeyedFlavour(
                lineComments: ["//"], sections: false, quotesValues: true, quotedKeys: true)))
        register(
            ["yaml", "yml"],
            .keyed(KeyedFlavour(
                lineComments: ["#"], sections: false, quotesValues: true, quotedKeys: false)))
        register(
            ["toml", "ini", "cfg", "conf", "properties", "env", "dotenv", "editorconfig"],
            .keyed(KeyedFlavour(
                lineComments: ["#", ";"], sections: true, quotesValues: true, quotedKeys: false)))

        return table
    }()
}
