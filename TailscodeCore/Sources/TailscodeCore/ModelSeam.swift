import CodingAgentKit
import Foundation

/// The moment the answering model changed inside one conversation.
public struct ModelSwitch: Sendable, Hashable {
    public let to: String
    public let from: String
    public let selection: ModelSelection

    public init(to: String, from: String, selection: ModelSelection) {
        self.to = to
        self.from = from
        self.selection = selection
    }

    /// The old model, said after the new one: "from DeepSeek V4".
    public var fromText: String { Localized.text("from %@", from) }

    public var line: String { to + " " + fromText }
}

/// Where each answer's model differs from the answer before it, kept as the transcript grows.
///
/// A transcript rebuild runs on every streamed token, so nothing here may cost the size of the
/// conversation: settled answers are read once and remembered, and a call after a token touches
/// only the answer still being written. The words compared are the ones a person reads — the pill's
/// word, not the id — so `opus` against `claude-opus-4-8` never says "Opus → Opus", and effort alone
/// never makes a seam. A seam never crosses backends, because that is a carry and starts a chat.
public struct ModelSeamTracker: Sendable {
    private var settled = 0
    private var lastID: String?
    private var lastWord: String?
    private var seams: [String: ModelSwitch] = [:]
    private var words: [String: String] = [:]
    private var catalogSize = -1

    public init() {}

    /// The seams of every answer so far, keyed by the id of the answer that follows one.
    public mutating func update(_ messages: [ChatMessage], catalog: [ModelInfo]) -> [String: ModelSwitch] {
        if catalog.count != catalogSize || settled > messages.count
            || (settled > 0 && messages[settled - 1].id != lastID)
        {
            self = ModelSeamTracker()
            catalogSize = catalog.count
        }
        var live: [String: ModelSwitch] = [:]
        var word = lastWord
        var committing = true
        var index = settled
        while index < messages.count {
            let message = messages[index]
            if message.role == .assistant, let modelID = message.modelID, !modelID.isEmpty {
                let selection = ModelSelection(providerID: message.providerID ?? "", modelID: modelID)
                let current = self.word(selection, catalog)
                if let previous = word, previous != current {
                    let entry = ModelSwitch(to: current, from: previous, selection: selection)
                    if committing { seams[message.id] = entry } else { live[message.id] = entry }
                }
                word = current
            }
            if message.isStreaming { committing = false }
            if committing {
                settled = index + 1
                lastID = message.id
                lastWord = word
            }
            index += 1
        }
        return live.isEmpty ? seams : seams.merging(live) { _, new in new }
    }

    private mutating func word(_ selection: ModelSelection, _ catalog: [ModelInfo]) -> String {
        let key = selection.providerID + "|" + selection.modelID
        if let known = words[key] { return known }
        let word = ModelBadge.word(for: selection, in: catalog)
        words[key] = word
        return word
    }
}
