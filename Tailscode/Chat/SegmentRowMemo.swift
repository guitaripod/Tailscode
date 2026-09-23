import CodingAgentKit
import Foundation
import TailscodeCore

/// The rows each text part was split into, kept from one transcript build to the next.
///
/// The transcript is built again from every message on every state the conversation emits, which
/// while a turn streams means every token, and splitting each answer into its paragraphs, fences,
/// tables and link cards was the bulk of that build: a long conversation re-split megabytes of
/// settled prose to add one word to the last paragraph. A part whose text, role and seal are what
/// they were last time is exactly the rows it was last time, so only the part still being written
/// is split again. Both desktops keep the same memo a message at a time.
final class SegmentRowMemo {
    private struct Entry {
        let text: String
        let role: MessageRole
        let sealed: Bool
        let embeds: Bool
        let rows: [ChatRow]
    }

    private var entries: [String: Entry] = [:]
    private var kept: [String: Entry] = [:]
    private var passEmbeds: Bool?

    func rows(
        for id: String, text: String, role: MessageRole, sealed: Bool,
        split: () -> [ChatRow]
    ) -> [ChatRow] {
        let embeds = passEmbeds ?? LinkEmbedsSetting.isEnabled
        passEmbeds = embeds
        if let hit = entries[id] ?? kept[id], hit.sealed == sealed, hit.role == role,
            hit.embeds == embeds, hit.text == text
        {
            kept[id] = hit
            return hit.rows
        }
        let rows = split()
        kept[id] = Entry(text: text, role: role, sealed: sealed, embeds: embeds, rows: rows)
        return rows
    }

    /// Ends one build. A part this build never asked about has left the conversation (or the
    /// window being drawn), so it is dropped instead of being carried for the life of the chat.
    func sweep() {
        entries = kept
        kept = [:]
        passEmbeds = nil
    }
}
