import Foundation

/// A split opened where the terminal is standing. The shell is the quickest way anyone has of
/// getting to a folder — `cd`, tab, a `z` jump — so the terminal beside the conversations is also
/// how a chat is aimed: walk there, press the chord, and the new half is a chat in that folder.
///
/// Toolkit-free on purpose: which folder counts, which server holds a chat there, and every word
/// of a refusal live here, so a desktop only asks its terminal where it stands and splits the
/// window.
public enum TerminalSplit {
    public enum Plan: Sendable, Equatable {
        case open(profileID: String, directory: String)
        case refused(Refusal)
    }

    public enum Refusal: Sendable, Equatable {
        case noTerminal
        case noDirectory

        public var words: String {
            switch self {
            case .noTerminal:
                return Localized.text("There is no shell open to take a folder from")
            case .noDirectory:
                return Localized.text("The terminal is not standing in a folder a chat can start in")
            }
        }
    }

    /// The chat goes to the server that holds the shell, in the folder the shell stands in: the
    /// shell runs on that machine, so the folder is that machine's and no other server could
    /// start a chat in it. A terminal with no shell yet, or one whose folder the server could not
    /// read, splits nothing and says why.
    public static func plan(directory: String?, server: String?) -> Plan {
        guard let server else { return .refused(.noTerminal) }
        guard let directory, directory.hasPrefix("/") else { return .refused(.noDirectory) }
        return .open(profileID: server, directory: directory)
    }

    /// The last folder of a path, which is what a row calls it: `/home/m/Dev/Tailscode` is
    /// `Tailscode`, and the root is `/`.
    public static func name(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init)
        return last ?? "/"
    }

    /// A path as a person writes it in a shell: the home folder is `~`. The folder is the
    /// server's, whose home this device cannot read, so home is recognised by its shape.
    public static func shortened(_ path: String) -> String {
        TerminalFollow.shortened(path)
    }
}
