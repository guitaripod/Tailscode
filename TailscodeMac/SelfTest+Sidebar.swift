import AppKit
import CodingAgentKit
import TailscodeCore

extension SelfTest {
    /// The chat list's row grammar, proved on real cells laid out at a sidebar's width: what makes
    /// an unread row findable, what a row says and when, and that nothing fights the title for
    /// its line.
    static func checkSidebarRows() throws -> Int {
        var checks = 0
        func claim(_ holds: Bool, _ words: String) throws {
            guard holds else { throw SelfTestFailure("chat list case failed: \(words)") }
            checks += 1
        }
        let width: CGFloat = 320
        let said = "Uploaded 1.84 (222); App Store Connect reports it VALID, and the old review was left alone."

        func entry(
            _ id: String, title: String = "Quick Ask: fix input focus and visuals",
            active: Bool = false, said: String? = nil
        ) -> SessionEntry {
            SessionEntry(
                profileID: "probe", profileName: "macbook", host: "macbook",
                backendType: .claudeCode,
                session: AgentSession(
                    id: id, agentType: .claudeCode, title: title, directory: "/tmp/Tailscode",
                    createdAt: Date().addingTimeInterval(-900), updatedAt: Date().addingTimeInterval(-600),
                    isActive: active, model: "claude-opus-5", reasoningEffort: "ultracode",
                    lastWords: said))
        }
        func row(
            _ entry: SessionEntry, unread: Bool = false, pinned: Bool = false, saved: Bool = false,
            presence: SessionPresence = .unobserved
        ) -> SessionRowModel {
            SessionRowModel(
                entry: entry, unreachable: false, unread: unread, saved: saved, pinned: pinned,
                presence: presence)
        }
        func cell(
            _ model: SessionRowModel, under section: SessionSection? = .recent,
            wide width: CGFloat = width
        ) -> SidebarSessionCell {
            let cell = SidebarSessionCell()
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: width).isActive = true
            cell.configure(
                with: model, marked: false,
                dress: SidebarRowDress(
                    vocabulary: ChatListVocabulary(namesServer: true, namesBackend: false),
                    section: section, news: ChatRowNews.reading(for: model)))
            cell.layoutSubtreeIfNeeded()
            return cell
        }
        func weight(_ font: NSFont) -> Int { NSFontManager.shared.weight(of: font) }

        let read = cell(row(entry("read")))
        let unread = cell(row(entry("unread", said: said), unread: true))
        let mute = cell(row(entry("mute"), unread: true))
        let working = cell(row(entry("working", active: true), unread: true))
        let asking = cell(row(entry("asking"), presence: .awaitingApproval))
        let failed = cell(row(entry("failed"), unread: true, presence: .failed))

        try claim(
            weight(unread.reading.titleFont) > weight(read.reading.titleFont),
            "an unread title is set heavier than a read one")
        try claim(
            unread.reading.titleColor.alphaComponent == 1
                && read.reading.titleColor.alphaComponent < 1,
            "and a read title steps back while an unread one is at full strength")
        try claim(
            abs(read.reading.titleColor.alphaComponent - ChatRowInk.recededTitle) < 0.01,
            "by the one figure all three desks share")
        try claim(
            weight(asking.reading.titleFont) == weight(unread.reading.titleFont),
            "a row waiting on the person is pressed as hard as an unread one")
        try claim(
            weight(working.reading.titleFont) == weight(read.reading.titleFont)
                && working.reading.titleColor.alphaComponent == 1,
            "a row that is working is full strength without the weight")

        try claim(unread.reading.showsDot && !read.reading.showsDot, "the dot is on the unread row only")
        try claim(
            !read.reading.showsBadge && !read.reading.showsDot,
            "a read row at rest leaves the state column empty")
        try claim(
            unread.reading.dotFrame.maxX <= unread.reading.titleFrame.minX,
            "the dot stands in the state column, left of the title, not after it")
        try claim(
            working.reading.showsBadge && !working.reading.showsDot,
            "a state takes the column from the dot")
        try claim(failed.reading.showsBadge, "a failed row nobody has seen still wears its state")

        let long = entry("long", title: "Nordic Languages on the Lock Screen for the version after 1.83")
        let underPinned = cell(row(long, pinned: true), under: .pinned)
        let underWorking = cell(row(entry("pinned-busy", active: true), pinned: true), under: .working)
        try claim(underPinned.reading.marks == 0, "a pinned row under PINNED does not say so again")
        try claim(underWorking.reading.marks == 1, "and wears its pin under any other heading")
        try claim(
            underPinned.reading.titleFrame.maxX >= width - 6,
            "a long title runs to the row's edge: nothing shares its line")
        let both = cell(row(long, pinned: true, saved: true), under: .working)
        try claim(
            both.reading.marks == 2 && both.reading.titleFrame.width > width * 0.6,
            "two marks cost the title a few points, never a third of its line")

        try claim(read.reading.news == nil, "a read row at rest has no news line")
        try claim(
            unread.reading.news?.string == said && unread.reading.newsLines == 2,
            "an unread finish quotes the answer, on up to two lines")
        try claim(
            mute.reading.news?.string == Localized.text("Finished"),
            "and says Finished where the server cannot quote it")
        let failedInk = failed.reading.news.flatMap {
            $0.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        }
        try claim(failedInk == MacTheme.Color.danger, "a failure is said in the failure colour")
        try claim(
            unread.fittingSize.height > read.fittingSize.height + 12,
            "a row with news is taller, so height itself says there is something to read")
        try claim(
            abs(read.fittingSize.height - mute.fittingSize.height) > 8
                && unread.fittingSize.height >= mute.fittingSize.height,
            "one line of news adds one line, a quoted answer up to two")

        let before = unread.fittingSize.height
        unread.setHovered(SidebarQuickState(pinned: false, saved: false, archived: false))
        unread.layoutSubtreeIfNeeded()
        try claim(
            abs(unread.fittingSize.height - before) < 0.5,
            "a row never changes height under the pointer resting on it")
        unread.setHovered(nil)

        func chipInk(_ cell: SidebarSessionCell) -> CGFloat {
            let line = cell.reading.detail
            guard line.length > 0,
                let color = line.attribute(.foregroundColor, at: line.length - 1, effectiveRange: nil)
                    as? NSColor
            else { return 1 }
            return color.alphaComponent
        }
        try claim(
            chipInk(read) < chipInk(unread),
            "a read row's model chip steps back with it and an unread one keeps its hues")
        try claim(
            read.reading.detail.string.hasPrefix("Tailscode"),
            "the last line leads with the project, the model follows")

        let whole = read.reading.detail.string
        try claim(
            whole.hasSuffix("ultracode"),
            "with room to spare the last line says who, where and with what in full")
        var last = whole
        for narrow in stride(from: CGFloat(300), through: 120, by: -20) {
            let said = cell(row(entry("fit-\(Int(narrow))")), wide: narrow).reading.detail.string
            try claim(
                said == last || (said.count < last.count && whole.hasPrefix(said)),
                "a narrower row says a shorter line, never a different one (\(Int(narrow)) pt)")
            try claim(
                !said.hasSuffix("ultracod") && !said.contains("ultrac…"),
                "and gives up a whole fact rather than the end of a word")
            last = said
        }
        try claim(last == "Tailscode", "down to the project alone, which is what the chat is known by")

        read.isChosen = true
        try claim(
            read.reading.titleColor.alphaComponent == 1,
            "the row the selection is on is never the stepped-back ink")
        read.isChosen = false

        let heading = SidebarHeaderCell()
        heading.configure(heading: SectionHeading(section: .recent(.today), rows: 5, fresh: 2))
        try claim(
            heading.reading.count == nil && heading.reading.fresh == Localized.text("%@ new", "2"),
            "a heading says how many of its rows are new and not how many it has")
        heading.configure(heading: SectionHeading(section: .recent(.today), rows: 5, fresh: 0))
        try claim(
            heading.reading.count == nil && heading.reading.fresh == nil,
            "and says nothing when none are")
        heading.configure(heading: SectionHeading(section: .needsYou, rows: 2, fresh: 2))
        try claim(
            heading.reading.count == "2" && heading.reading.fresh == nil,
            "the fleet's two headings keep their totals")
        return checks
    }
}
