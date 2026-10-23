import CodingAgentKit
import Foundation

extension ModelChooser {
    /// What a server that is not answering amounts to, said in place of a claim about its catalog.
    /// A restart is a state, not an empty list: the words the header and the empty body show must
    /// name the state, or a reader who restarted the server is told it has no models while the
    /// answer is on the way back up.
    public var serverReading: String? {
        guard let shown else { return nil }
        switch shown.isReachable {
        case nil where shown.models.isEmpty:
            return Localized.text("Asking the server for its models…")
        case false where shown.models.isEmpty:
            return Localized.text("Server is not answering — models will appear when it comes back")
        case false:
            return Localized.text("Server is not answering — showing the last known list")
        default:
            return nil
        }
    }

    /// Whether anything is standing between the reader and the whole catalog.
    public var isNarrowed: Bool { !query.isEmpty || door != nil }

    /// What the list amounts to right now: the shown machine's whole catalog when nothing is
    /// narrowing it, and otherwise how much of it survived — a count that moves as you type is
    /// the only honest way for a header to answer "is it still looking".
    public var summary: String {
        let whole = wholeMachine
        guard !whole.isEmpty else {
            return serverReading ?? Localized.text("This server lists no models")
        }
        guard !isNarrowed else {
            var parts = [Localized.text("%@ of %@ models", "\(matched)", "\(whole.count)")]
            if let shownDoor { parts.append(Localized.text("via %@", shownDoor.title)) }
            if elsewhereMatched > 0 {
                parts.append(Localized.text("%@ elsewhere", "\(elsewhereMatched)"))
            }
            return parts.joined(separator: " · ")
        }
        return catalogSummary
    }

    /// What the shown machine's catalog amounts to, said once at the top instead of implied by
    /// scrolling.
    public var catalogSummary: String {
        let mine = wholeMachine
        guard !mine.isEmpty else {
            return serverReading ?? Localized.text("This server lists no models")
        }
        var parts = [Self.modelCount(mine.count)]
        if let reading = serverReading { parts.append(reading.lowercased()) }
        let providers = Set(mine.flatMap { $0.offers.map(\.providerID) })
        if providers.count > 1 { parts.append(Self.providerCount(providers.count)) }
        let local = mine.filter(\.isLocal).count
        if local > 0 { parts.append(Localized.text("%@ on its own machine", "\(local)")) }
        let walled = mine.filter { walls[$0.selection.rawValue] != nil }.count
        if walled > 0 { parts.append(Localized.text("%@ used up", "\(walled)")) }
        return parts.joined(separator: " · ")
    }

    static func serverCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 server") : Localized.text("%@ servers", "\(count)")
    }

    static func modelCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 model") : Localized.text("%@ models", "\(count)")
    }

    static func providerCount(_ count: Int) -> String {
        count == 1 ? Localized.text("1 provider") : Localized.text("%@ providers", "\(count)")
    }

    public var hint: String {
        var parts = [Localized.text("↑↓ chooses")]
        parts.append(Localized.text("⌃→ opens · ⌃← folds"))
        if showsMachines {
            parts.append(Localized.text("⌃1–%@ servers", "\(machines.count)"))
        }
        if showsDoors {
            parts.append(Localized.text("⌥1–%@ providers · ⌥0 all", "\(min(doors.count, 9))"))
        }
        parts.append(Localized.text("enter picks · esc closes"))
        return parts.joined(separator: " · ")
    }

    /// Said when nothing survived, naming the machine as well as the word — a reader who forgot
    /// which tab is showing would otherwise read an empty list as a catalog that lost a model.
    ///
    /// Empty means nothing under any heading — not no rows: past `foldFrom` the families arrive
    /// shut and `rows` is legitimately empty while a dozen headings each say how many they hold,
    /// and a chooser that read that as "runs none of these models" drew the refusal over the
    /// very list it was refusing.
    public var emptyResult: String? {
        guard sections.allSatisfy({ $0.count == 0 }) else { return nil }
        guard !query.isEmpty else {
            if let shownDoor {
                return Localized.text("%@ runs none of these models", shownDoor.title)
            }
            return serverReading
        }
        if let shownDoor {
            return Localized.text("No model via %@ matches “%@”", shownDoor.title, query)
        }
        guard showsMachines, let shownMachine else {
            return Localized.text("No model matches “%@”", query)
        }
        return Localized.text("No model on %@ matches “%@”", shownMachine.title, query)
    }
}
