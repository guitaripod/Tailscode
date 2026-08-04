import Foundation

/// What this process was actually started with, asked of the kernel rather than of the runtime.
///
/// In this binary `CommandLine.argc` is 0 and `CommandLine.arguments` is empty — the Swift
/// runtime's copy of `argv` never survives whatever the GTK/WebKit/mpv link graph does on the way
/// to `main`, and `ProcessInfo.processInfo.arguments`, which reads the same globals, is left with
/// the executable path alone. A trivial package on the same toolchain has both. The consequence
/// was not a missing flag: every option — `--version`, `--help`, `--selftest`, `--connect` —
/// silently became "open a window", so a `--version` in a build script registered on the session
/// bus, took the app's name, and turned every launch after it into a remote activation of a
/// process nobody could see.
///
/// `/proc/self/cmdline` is the kernel's own record, NUL-separated, and it cannot be lost by a
/// linker. Everything that asks what it was invoked with asks here.
enum Arguments {
    static let all: [String] = fromProc() ?? CommandLine.arguments

    static var flags: ArraySlice<String> { all.dropFirst() }

    static func contains(_ flag: String) -> Bool { all.contains(flag) }

    /// The word after a flag, when the flag is one that takes one.
    static func value(after flag: String) -> String? {
        guard let index = all.firstIndex(of: flag), index + 1 < all.count else { return nil }
        let next = all[index + 1]
        return next.hasPrefix("-") ? nil : next
    }

    private static func fromProc() -> [String]? {
        guard let raw = FileManager.default.contents(atPath: "/proc/self/cmdline"), !raw.isEmpty
        else { return nil }
        let parts = raw.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        return parts.isEmpty ? nil : parts
    }
}
