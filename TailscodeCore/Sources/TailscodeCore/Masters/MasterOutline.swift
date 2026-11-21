import CodingAgentKit
import Foundation

/// The front page of a master's editor: its name, what it is for and where it works are typed
/// there, and every other part is one line that says what it holds and opens to be changed. Three
/// clients read the same lines, so a part reads the same wherever it is made.
public enum MasterOutline {
    public enum Part: String, CaseIterable, Sendable {
        case charter, skills, notebook, notes, bench, guards, model
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public var part: Part
        public var title: String
        public var value: String
        /// False while the part holds nothing of the person's own, so a client can draw it quieter.
        public var isSet: Bool
        public var id: String { part.rawValue }
    }

    /// The parts in the order a client lists them. The first notes only appear for a draft that
    /// came with some.
    public static func rows(
        _ draft: ExpertDraft, kept: Int = 0, modelName: String? = nil, calendar: Calendar = .current, now: Date = Date()
    ) -> [Row] {
        Part.allCases.compactMap { part in
            if part == .notes, (draft.notes ?? []).isEmpty { return nil }
            return row(part, draft, kept: kept, modelName: modelName, calendar: calendar, now: now)
        }
    }

    public static func row(
        _ part: Part, _ draft: ExpertDraft, kept: Int = 0, modelName: String? = nil, calendar: Calendar = .current,
        now: Date = Date()
    ) -> Row {
        switch part {
        case .charter:
            let count = words(draft.charter ?? "")
            return Row(part: part, title: MasterWords.charter, value: wordCount(count), isSet: count > 0)
        case .skills:
            let names = draft.skills ?? []
            return Row(part: part, title: MasterWords.skills, value: listed(names), isSet: !names.isEmpty)
        case .notebook:
            let path = draft.notebookPath?.trimmingCharacters(in: .whitespaces) ?? ""
            return Row(
                part: part, title: MasterWords.notebook, value: path.isEmpty ? MasterWords.notebookOwnShort : MasterReading.shortPath(path),
                isSet: !path.isEmpty)
        case .notes:
            let all = draft.notes?.count ?? 0
            return Row(
                part: part, title: MasterWords.firstNotes, value: Localized.text("%d of %d kept", kept, all), isSet: kept > 0)
        case .bench:
            let names = (draft.bench ?? []).map(\.name)
            return Row(part: part, title: MasterWords.bench, value: listed(names), isSet: !names.isEmpty)
        case .guards:
            let count = draft.guards?.count ?? 0
            guard count > 0 else {
                return Row(part: part, title: MasterWords.guards, value: Localized.text("None"), isSet: false)
            }
            let amount = count == 1 ? Localized.text("1 guard") : Localized.text("%d guards", count)
            let when = draft.guardRule.map {
                ScheduleWords.lowered(ScheduleWords.when($0, calendar: calendar, now: now))
            } ?? ScheduleWords.lowered(MasterWords.guardsOnDemand)
            return Row(part: part, title: MasterWords.guards, value: amount + " · " + when, isSet: true)
        case .model:
            let model = modelName ?? draft.model
            let parts = [model, draft.effort].compactMap { $0 }.filter { !$0.isEmpty }
            return Row(
                part: part, title: MasterWords.model,
                value: parts.isEmpty ? Localized.text("The machine’s default") : parts.joined(separator: " · "),
                isSet: !parts.isEmpty)
        }
    }

    public static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func wordCount(_ count: Int) -> String {
        switch count {
        case 0: return Localized.text("None yet")
        case 1: return Localized.text("1 word")
        default: return Localized.text("%d words", count)
        }
    }

    /// The first two names and how many more, or that there are none.
    public static func listed(_ names: [String]) -> String {
        guard !names.isEmpty else { return Localized.text("None") }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? shown + " +\(names.count - 2)" : shown
    }

    /// A draft the machine made laid over what the person had typed: what they typed stays, and
    /// everything they had left empty is the machine's.
    public static func merged(_ drafted: ExpertDraft, over typed: ExpertDraft) -> ExpertDraft {
        var result = drafted
        if !typed.name.trimmingCharacters(in: .whitespaces).isEmpty {
            result.name = typed.name
            result.glyph = typed.glyph
            result.hue = typed.hue ?? drafted.hue
        }
        if let purpose = typed.purpose, !purpose.trimmingCharacters(in: .whitespaces).isEmpty { result.purpose = purpose }
        if let directory = typed.directory, !directory.trimmingCharacters(in: .whitespaces).isEmpty {
            result.directory = directory
        }
        if let model = typed.model { result.model = model }
        if let effort = typed.effort { result.effort = effort }
        return result
    }

    /// Whether a new master still has nothing the machine could not write for it: the moment a
    /// client offers to draft it from a skill.
    public static func canDraft(_ draft: ExpertDraft) -> Bool {
        words(draft.charter ?? "") == 0 && (draft.notes ?? []).isEmpty && (draft.bench ?? []).isEmpty
            && (draft.guards ?? []).isEmpty
    }
}
