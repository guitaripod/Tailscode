import Foundation

/// The language table. Each entry is a comment style, a string style and a word list — the amount
/// of grammar a reader actually decodes by colour. Anything finer (a type inferred, a shadowed
/// binding) belongs to a compiler, not to a transcript.
enum Grammars {
    private static let cQuotes: [SyntaxGrammar.Quote] = [
        SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'"),
    ]
    private static let cBlocks = [SyntaxGrammar.Block("/*", "*/")]

    static let swift = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [
            SyntaxGrammar.Quote("\"\"\"", multiline: true, interpolations: [.init("\\(", ")")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("\\(", ")")]),
        ],
        keywords: [
            "actor", "as", "associatedtype", "async", "await", "borrowing", "break", "case",
            "catch", "class", "consuming", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "each", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
            "infix", "init", "inout", "internal", "is", "lazy", "let", "macro", "mutating",
            "nil", "nonisolated", "nonmutating", "open", "operator", "override", "package",
            "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat",
            "required", "rethrows", "return", "self", "sending", "set", "some", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
            "weak", "where", "while", "willSet", "unowned", "unsafe", "any", "consume", "copy",
        ],
        builtins: [
            "Any", "AnyObject", "Array", "Bool", "Character", "Data", "Date", "Dictionary",
            "Double", "Error", "Float", "Int", "Never", "Optional", "Result", "Sendable", "Set",
            "String", "Task", "UInt", "URL", "Void",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let rust = SyntaxGrammar(
        lineComments: ["///", "//!", "//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [SyntaxGrammar.Quote("r#\"", "\"#", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\"", multiline: true), SyntaxGrammar.Quote("'")],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
            "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
            "trait", "true", "type", "union", "unsafe", "use", "where", "while", "yield",
        ],
        builtins: [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
            "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result",
            "Box", "Rc", "Arc", "HashMap", "HashSet", "Some", "None", "Ok", "Err",
        ],
        capitalizedIsType: true,
        attributeSigils: ["#["])

    static let javascript = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [
            SyntaxGrammar.Quote("`", multiline: true, interpolations: [.init("${", "}")]),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "declare", "default", "delete", "do", "else", "enum", "export", "extends",
            "false", "finally", "for", "from", "function", "get", "if", "implements", "import",
            "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of",
            "private", "protected", "public", "readonly", "return", "satisfies", "set", "static",
            "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined",
            "var", "void", "while", "yield",
        ],
        builtins: [
            "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number", "Object",
            "Promise", "RegExp", "Set", "String", "Symbol", "any", "bigint", "boolean", "never",
            "number", "object", "string", "unknown", "console", "document", "window",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "$"])

    static let python = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true),
            SyntaxGrammar.Quote("'''", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
            "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise",
            "return", "True", "try", "while", "with", "yield",
        ],
        builtins: [
            "bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple", "type",
            "self", "cls", "print", "len", "range", "open", "super", "Exception",
        ],
        attributeSigils: ["@"])

    static let go = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("`", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
        ],
        builtins: [
            "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
            "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
            "uint32", "uint64", "uintptr", "nil", "true", "false", "make", "new", "len", "cap",
            "append", "copy", "delete", "panic", "recover",
        ])

    static let c = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: cQuotes,
        keywords: [
            "auto", "break", "case", "const", "continue", "default", "do", "else", "enum",
            "extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof",
            "static", "struct", "switch", "typedef", "union", "volatile", "while", "_Atomic",
        ],
        builtins: [
            "bool", "char", "double", "float", "int", "long", "short", "signed", "size_t",
            "unsigned", "void", "NULL", "true", "false", "uint8_t", "uint32_t", "int32_t",
        ],
        attributeSigils: ["#"])

    static let cpp = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: cQuotes,
        keywords: c.keywords.union([
            "class", "namespace", "template", "typename", "public", "private", "protected",
            "virtual", "override", "final", "friend", "operator", "new", "delete", "this",
            "using", "try", "catch", "throw", "noexcept", "constexpr", "consteval", "concept",
            "requires", "co_await", "co_return", "co_yield", "mutable", "explicit",
            "interface", "implementation", "property", "synthesize", "end", "selector",
        ]),
        builtins: c.builtins.union([
            "std", "string", "vector", "map", "set", "nullptr", "auto", "id", "BOOL", "NSString",
            "NSArray", "NSDictionary", "YES", "NO",
        ]),
        capitalizedIsType: true,
        attributeSigils: ["#", "@"])

    static let java = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
            "default", "do", "else", "enum", "extends", "final", "finally", "for", "if",
            "implements", "import", "instanceof", "interface", "native", "new", "package",
            "private", "protected", "public", "record", "return", "sealed", "static", "super",
            "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var",
            "void", "volatile", "while", "yield", "def", "trait",
        ],
        builtins: [
            "boolean", "byte", "char", "double", "float", "int", "long", "short", "String",
            "Object", "List", "Map", "Set", "Integer", "Boolean", "Double", "null", "true",
            "false",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let kotlin = SyntaxGrammar(
        lineComments: ["//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [
            SyntaxGrammar.Quote(
                "\"\"\"", multiline: true, interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "actual", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "crossinline", "data", "delegate", "do", "else", "enum",
            "expect", "external", "false", "final", "finally", "for", "fun", "get", "if", "import",
            "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit",
            "no", "null", "object", "open", "operator", "out", "override", "package", "private",
            "protected", "public", "reified", "return", "sealed", "set", "super", "suspend",
            "this", "throw", "true", "try", "typealias", "val", "var", "vararg", "when", "where",
            "while",
        ],
        builtins: [
            "Any", "Array", "Boolean", "Byte", "Char", "Double", "Float", "Int", "List", "Long",
            "Map", "Nothing", "Set", "Short", "String", "Unit",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let csharp = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("@\"", "\"", escape: nil, multiline: true),
            SyntaxGrammar.Quote("$\"", "\"", interpolations: [.init("{", "}")]),
            SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "as", "async", "await", "base", "break", "case", "catch", "checked",
            "class", "const", "continue", "default", "delegate", "do", "else", "enum", "event",
            "explicit", "extern", "false", "finally", "fixed", "for", "foreach", "get", "goto",
            "if", "implicit", "in", "init", "interface", "internal", "is", "lock", "namespace",
            "new", "null", "operator", "out", "override", "params", "private", "protected",
            "public", "readonly", "record", "ref", "return", "sealed", "set", "sizeof",
            "stackalloc", "static", "struct", "switch", "this", "throw", "true", "try", "typeof",
            "unchecked", "unsafe", "using", "var", "virtual", "void", "volatile", "when", "where",
            "while", "yield",
        ],
        builtins: [
            "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long",
            "nint", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "Task",
            "List", "Dictionary",
        ],
        capitalizedIsType: true,
        attributeSigils: ["#"])

    static let ruby = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("=begin", "=end")],
        quotes: [
            SyntaxGrammar.Quote("\"", interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("'"), SyntaxGrammar.Quote("%w(", ")"),
        ],
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
            "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader",
            "attr_writer", "require", "require_relative", "include", "extend",
        ],
        builtins: ["Array", "Hash", "String", "Symbol", "Integer", "Float", "Proc", "Struct"],
        capitalizedIsType: true,
        identifierExtras: ["_", "?", "!"])

    static let shell = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [
            SyntaxGrammar.Quote(
                "\"", multiline: true, interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'", escape: nil, multiline: true),
        ],
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
            "return", "select", "then", "time", "until", "while", "export", "local", "readonly",
            "declare", "source", "alias", "unset", "shift", "trap", "set",
        ],
        builtins: [
            "echo", "cd", "ls", "cat", "grep", "sed", "awk", "curl", "git", "rm", "cp", "mv",
            "mkdir", "sudo", "chmod", "chown", "find", "xargs", "make", "docker", "kubectl",
            "npm", "cargo", "swift", "python", "python3", "pip", "brew", "apt", "pacman", "ssh",
            "rsync", "true", "false", "exit",
        ],
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let php = SyntaxGrammar(
        lineComments: ["//", "#"],
        blocks: cBlocks,
        quotes: [
            SyntaxGrammar.Quote("\"", interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
            "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
            "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
            "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
            "goto", "if", "implements", "include", "instanceof", "insteadof", "interface", "isset",
            "list", "match", "namespace", "new", "or", "print", "private", "protected", "public",
            "readonly", "require", "return", "static", "switch", "throw", "trait", "try", "unset",
            "use", "var", "while", "xor", "yield", "true", "false", "null",
        ],
        capitalizedIsType: true,
        dollarVariables: true)

    static let lua = SyntaxGrammar(
        lineComments: ["--"],
        blocks: [SyntaxGrammar.Block("--[[", "]]")],
        quotes: [SyntaxGrammar.Quote("[[", "]]", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
            "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until",
            "while",
        ],
        builtins: ["print", "pairs", "ipairs", "require", "table", "string", "math", "io", "os"])

    static let sql = SyntaxGrammar(
        lineComments: ["--"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("'", escape: nil), SyntaxGrammar.Quote("\"", escape: nil)],
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast",
            "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
            "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full",
            "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join",
            "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer",
            "primary", "references", "returning", "right", "rollback", "select", "set", "table",
            "then", "transaction", "union", "unique", "update", "using", "values", "view", "when",
            "where", "with",
        ],
        builtins: [
            "bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "double", "float",
            "int", "integer", "json", "numeric", "real", "serial", "smallint", "text", "time",
            "timestamp", "uuid", "varchar", "count", "sum", "avg", "min", "max", "coalesce",
        ],
        caseInsensitive: true)

    static let haskell = SyntaxGrammar(
        lineComments: ["--"],
        blocks: [SyntaxGrammar.Block("{-", "-}", nests: true)],
        quotes: cQuotes,
        keywords: [
            "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if",
            "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype",
            "of", "then", "type", "where",
        ],
        builtins: ["Bool", "Char", "Double", "Either", "Int", "Integer", "IO", "Maybe", "String"],
        capitalizedIsType: true,
        identifierExtras: ["_", "'"])

    static let elixir = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [
            SyntaxGrammar.Quote("\"\"\"", multiline: true, interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "after", "and", "case", "catch", "cond", "def", "defexception", "defimpl", "defmacro",
            "defmodule", "defp", "defprotocol", "defstruct", "do", "else", "end", "false", "fn",
            "for", "if", "import", "in", "nil", "not", "or", "quote", "raise", "receive",
            "require", "rescue", "true", "try", "unless", "unquote", "use", "when", "with",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "?", "!"])

    static let zig = SyntaxGrammar(
        lineComments: ["///", "//"],
        quotes: [SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
            "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum",
            "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "noalias",
            "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct",
            "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "usingnamespace",
            "var", "volatile", "while",
        ],
        builtins: [
            "bool", "f16", "f32", "f64", "i8", "i16", "i32", "i64", "isize", "u8", "u16", "u32",
            "u64", "usize", "void", "type", "null", "true", "false", "undefined", "anyerror",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let dart = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("'''", multiline: true),
            SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch",
            "class", "const", "continue", "covariant", "default", "deferred", "do", "dynamic",
            "else", "enum", "export", "extends", "extension", "external", "factory", "false",
            "final", "finally", "for", "get", "hide", "if", "implements", "import", "in",
            "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator",
            "part", "required", "rethrow", "return", "sealed", "set", "show", "static", "super",
            "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "when",
            "while", "with", "yield",
        ],
        builtins: ["bool", "double", "int", "num", "String", "List", "Map", "Set", "Future", "Stream"],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let scala = SyntaxGrammar(
        lineComments: ["//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "case", "catch", "class", "def", "do", "else", "enum", "extends", "false",
            "final", "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy",
            "match", "new", "null", "object", "override", "package", "private", "protected",
            "return", "sealed", "super", "this", "throw", "trait", "true", "try", "type", "using",
            "val", "var", "while", "with", "yield",
        ],
        builtins: ["Any", "Boolean", "Double", "Int", "List", "Map", "Option", "Seq", "String", "Unit"],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let perl = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "and", "cmp", "continue", "do", "else", "elsif", "eq", "exit", "for", "foreach",
            "if", "last", "local", "my", "ne", "next", "no", "not", "or", "our", "package",
            "redo", "require", "return", "sub", "unless", "until", "use", "wantarray", "while",
            "xor",
        ],
        dollarVariables: true)

    static let r = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "break", "else", "for", "function", "if", "in", "next", "repeat", "return", "while",
            "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "library", "require",
        ],
        identifierExtras: ["_", "."])

    static let julia = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("#=", "=#", nests: true)],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do",
            "else", "elseif", "end", "export", "false", "finally", "for", "function", "global",
            "if", "import", "let", "local", "macro", "module", "mutable", "primitive", "quote",
            "return", "struct", "true", "try", "type", "using", "where", "while",
        ],
        builtins: ["Bool", "Float64", "Int", "Int64", "String", "Vector", "Matrix", "Dict", "Array"],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "!"])

    static let nix = SyntaxGrammar(
        lineComments: ["#"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("''", multiline: true), SyntaxGrammar.Quote("\"")],
        keywords: [
            "assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with",
            "true", "false", "null", "import",
        ],
        identifierExtras: ["_", "-", "'"])

    static let lisp = SyntaxGrammar(
        lineComments: [";"],
        quotes: [SyntaxGrammar.Quote("\"", multiline: true)],
        keywords: [
            "and", "case", "cond", "def", "defmacro", "defn", "defn-", "defonce", "defparameter",
            "defprotocol", "defrecord", "defstruct", "defun", "defvar", "do", "doseq", "dotimes",
            "fn", "for", "if", "lambda", "let", "let*", "letfn", "loop", "ns", "or", "quote",
            "recur", "require", "setq", "when", "while", "nil", "true", "false",
        ],
        callIsFunction: false,
        identifierExtras: ["_", "-", "*", "?", "!", "+", "/", ">", "<", "="])

    static let powershell = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("<#", "#>")],
        quotes: [SyntaxGrammar.Quote("\"", escape: "`"), SyntaxGrammar.Quote("'", escape: nil)],
        keywords: [
            "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else",
            "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "function",
            "if", "in", "param", "process", "return", "switch", "throw", "trap", "try", "until",
            "using", "while",
        ],
        caseInsensitive: true,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let hcl = SyntaxGrammar(
        lineComments: ["#", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("\"")],
        keywords: [
            "data", "for", "for_each", "if", "in", "locals", "module", "output", "provider",
            "resource", "terraform", "variable", "true", "false", "null", "depends_on", "count",
        ],
        builtins: ["bool", "list", "map", "number", "object", "set", "string", "tuple", "any"],
        identifierExtras: ["_", "-"])

    static let dockerfile = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK",
            "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME",
            "WORKDIR", "AS",
        ],
        caseInsensitive: false,
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let make = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "define", "else", "endef", "endif", "export", "ifdef", "ifeq", "ifndef", "ifneq",
            "include", "override", "unexport", "vpath", "add_executable", "add_library",
            "find_package", "if", "elseif", "foreach", "function", "endfunction",
            "macro", "endmacro", "set", "target_link_libraries", "project", "cmake_minimum_required",
        ],
        caseInsensitive: true,
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-", "."])

    static let vim = SyntaxGrammar(
        lineComments: ["\""],
        quotes: [SyntaxGrammar.Quote("'", escape: nil)],
        keywords: [
            "au", "augroup", "autocmd", "call", "command", "echo", "elseif", "else", "endfor",
            "endfunction", "endif", "endwhile", "exe", "execute", "for", "function", "if", "let",
            "map", "nnoremap", "noremap", "return", "set", "setlocal", "source", "vnoremap",
            "while", "inoremap",
        ],
        identifierExtras: ["_", "#", ":"])
}
