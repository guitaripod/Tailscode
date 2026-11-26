import CodingAgentKit
import Foundation
import TailscodeCore

/// The rows each text part was split into, kept from one transcript build to the next.
///
/// The transcript is built again from every message on every state the conversation emits, which
/// while a turn streams means every token, and splitting each answer into its paragraphs, fences
/// and tables was the bulk of that build: a long conversation re-split megabytes of settled prose
/// to add one word to the last paragraph. A part whose text, role and seal are what they were last
/// time is exactly the rows it was last time, so only the part still being written is split
/// again. Both desktops keep the same memo a message at a time.
///
/// The addresses a paragraph mentions are kept the same way, keyed by the row and its text and by
/// whether link previews are on, because a link rail reads them off every settled run on every
/// build and finding an address is a scan of the text.
final class SegmentRowMemo {
    private struct Entry {
        let text: String
        let role: MessageRole
        let sealed: Bool
        let rows: [ChatRow]
    }

    private struct Links {
        let text: String
        let addresses: [String]
    }

    /// What a message's rows depend on besides the message: the prompt that opened its turn, the
    /// response strip, and the brain that consumes some of its parts.
    struct MessageContext: Hashable {
        let promptID: String?
        let promptAt: Date?
        let stats: Bool
        let brainStamp: Int?
        let brainShowsRows: Bool
        let brainAnchor: Bool
    }

    private final class MessageEntry {
        let fingerprint: Int
        let context: MessageContext
        let toolIDs: [String]
        let rows: [ChatRow]
        var lastUsed: Int

        init(
            fingerprint: Int, context: MessageContext, toolIDs: [String], rows: [ChatRow],
            lastUsed: Int
        ) {
            self.fingerprint = fingerprint
            self.context = context
            self.toolIDs = toolIDs
            self.rows = rows
            self.lastUsed = lastUsed
        }
    }

    private var entries: [String: Entry] = [:]
    private var messageEntries: [String: MessageEntry] = [:]
    private var build = 0
    private var touched = 0
    private(set) var messageHits = 0
    private(set) var messageBuilds = 0
    private var kept: [String: Entry] = [:]
    private var links: [String: Links] = [:]
    private var keptLinks: [String: Links] = [:]

    /// The rows a message made last time, when nothing it depends on has moved: the message is
    /// the one the rows were made from, its context is the same, and no call in it has since been
    /// claimed by a card of its own. A transcript is built again for every token, and a settled
    /// message is the same rows every time.
    ///
    /// What it is asked is a fingerprint rather than the message: the server sends the whole
    /// conversation again for every token, with every settled message decoded into fresh strings,
    /// so comparing a long transcript by value re-read megabytes on each token to learn that only
    /// the last message had grown. The fingerprint hashes identity plus each part's length and
    /// ends, which moves whenever the words do and costs nothing to read.
    func rows(
        forMessage message: ChatMessage, context: MessageContext, isClaimed: (String) -> Bool
    ) -> [ChatRow]? {
        guard let hit = messageEntries[message.id],
            hit.context == context, hit.fingerprint == Self.fingerprint(of: message),
            !hit.toolIDs.contains(where: isClaimed)
        else { return nil }
        if hit.lastUsed != build {
            hit.lastUsed = build
            touched += 1
        }
        messageHits += 1
        return hit.rows
    }

    /// Remembers the rows a settled, plain message made.
    func keep(
        message: ChatMessage, context: MessageContext, toolIDs: [String], rows: [ChatRow]
    ) {
        messageBuilds += 1
        if messageEntries[message.id]?.lastUsed != build { touched += 1 }
        messageEntries[message.id] = MessageEntry(
            fingerprint: Self.fingerprint(of: message), context: context, toolIDs: toolIDs,
            rows: rows, lastUsed: build)
    }

    /// What a message looks like to the memo without reading it: the fields that move when its
    /// words do, with lengths and ends rather than the bytes.
    static func fingerprint(of message: ChatMessage) -> Int {
        var hasher = Hasher()
        hasher.combine(message.id)
        hasher.combine(message.role)
        hasher.combine(message.isStreaming)
        hasher.combine(message.completedAt)
        hasher.combine(message.parts.count)
        for part in message.parts {
            hasher.combine(part.id)
            switch part.kind {
            case .text(let value), .reasoning(let value):
                hasher.combine(0)
                hasher.combine(value.utf8.count)
                hasher.combine(Int(value.utf8.first ?? 0))
                hasher.combine(Int(value.utf8.last ?? 0))
            case .tool(let call):
                hasher.combine(1)
                hasher.combine(call.status)
                hasher.combine(call.name)
                if let output = call.output {
                    hasher.combine(output.utf8.count)
                    hasher.combine(Int(output.utf8.last ?? 0))
                } else {
                    hasher.combine(-1)
                }
                hasher.combine(call.background)
            case .file(let file):
                hasher.combine(2)
                hasher.combine(file)
            case .compaction(let compaction):
                hasher.combine(3)
                hasher.combine(compaction)
            case .note(let note):
                hasher.combine(4)
                hasher.combine(note.subject)
            case .unknown(let type):
                hasher.combine(5)
                hasher.combine(type)
            }
        }
        return hasher.finalize()
    }

    func rows(
        for id: String, text: String, role: MessageRole, sealed: Bool,
        split: () -> [ChatRow]
    ) -> [ChatRow] {
        if let hit = entries[id] ?? kept[id], hit.sealed == sealed, hit.role == role,
            hit.text == text
        {
            kept[id] = hit
            return hit.rows
        }
        let rows = split()
        kept[id] = Entry(text: text, role: role, sealed: sealed, rows: rows)
        return rows
    }

    /// The addresses written in one prose row, in order. A row still being written is asked
    /// with the growing rule, which drops an address that runs to the end of the text, and is
    /// never remembered, because the next word may be the rest of it.
    func addresses(forRow id: String, text: String, growing: Bool) -> [String] {
        guard !growing else { return LinkEmbedPolicy.candidates(in: text, growing: true) }
        if let hit = links[id] ?? keptLinks[id], hit.text == text {
            keptLinks[id] = hit
            return hit.addresses
        }
        let found = LinkEmbedPolicy.candidates(in: text)
        keptLinks[id] = Links(text: text, addresses: found)
        return found
    }

    /// Ends one build. A part this build never asked about has left the conversation (or the
    /// window being drawn), so it is dropped instead of being carried for the life of the chat.
    /// A message's rows are marked where they stand rather than moved into a new table, so a build
    /// that finds every message settled writes nothing but a counter; the table is swept of what
    /// no build has asked for only once those have grown to half again its live size.
    func sweep() {
        if messageEntries.count > touched + max(64, touched / 2) {
            let current = build
            messageEntries = messageEntries.filter { $0.value.lastUsed == current }
        }
        build += 1
        touched = 0
        entries = kept
        kept = [:]
        links = keptLinks
        keptLinks = [:]
    }
}
