import Foundation

/// A split opened where the terminal is standing. The shell is the quickest way anyone has of
/// getting to a folder — `cd`, tab, a `z` jump — so the terminal beside the conversations is also
/// how a chat is aimed: walk there, press the chord, and the new half is a chat in that folder.
///
/// Toolkit-free on purpose: which folder counts, which server may hold a chat there, and every word
/// of a refusal live here, so a desktop only reads its shell's directory and splits the window.
public enum TerminalSplit {
    /// A configured server as this decision sees it: only whether the terminal's disk is its disk.
    public struct Server: Sendable, Equatable {
        public let profileID: String
        public let isLocal: Bool
        public let reachable: Bool

        public init(profileID: String, isLocal: Bool, reachable: Bool = true) {
            self.profileID = profileID
            self.isLocal = isLocal
            self.reachable = reachable
        }
    }

    public enum Plan: Sendable, Equatable {
        case open(profileID: String, directory: String)
        case refused(Refusal)
    }

    public enum Refusal: Sendable, Equatable {
        case oneCommandAtATime
        case noDirectory
        case noLocalServer

        public var words: String {
            switch self {
            case .oneCommandAtATime:
                return Localized.text(
                    "This terminal runs one command at a time, so a cd does not carry over to a split")
            case .noDirectory:
                return Localized.text("The terminal is not standing in a folder a chat can start in")
            case .noLocalServer:
                return Localized.text(
                    "The terminal's folders belong to this machine and none of your servers runs on it")
            }
        }
    }

    /// The chat goes to the server whose disk the terminal is standing on: the pane's own server
    /// when that is this machine, otherwise the first local one that answers, otherwise any local
    /// one — a server that is down says so when the chat is minted, in the words every new chat
    /// uses, rather than being passed over for one the person did not mean.
    public static func plan(directory: String?, servers: [Server], preferred: String?) -> Plan {
        guard let directory else { return .refused(.noDirectory) }
        let local = servers.filter(\.isLocal)
        guard
            let chosen = local.first(where: { $0.profileID == preferred && $0.reachable })
                ?? local.first(where: \.reachable) ?? local.first
        else { return .refused(.noLocalServer) }
        return .open(profileID: chosen.profileID, directory: directory)
    }

    /// The last folder of a path, which is what a row calls it: `/home/m/Dev/Tailscode` is
    /// `Tailscode`, and the root is `/`.
    public static func name(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init)
        return last ?? "/"
    }

    /// A path as a person writes it in a shell: the home folder is `~`.
    public static func shortened(
        _ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if path == home { return "~" }
        guard !home.isEmpty, home != "/", path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// What a shell's working-directory link names, or nil when the link says there is no place to
    /// start a chat: nothing, something relative, or a folder that was deleted while the shell
    /// stood in it, which the kernel reports as the old path with a suffix.
    public static func directory(fromLink target: String?) -> String? {
        guard let target, target.hasPrefix("/"), !target.hasSuffix(" (deleted)") else { return nil }
        return target
    }
}
