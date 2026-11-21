import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

extension ChatViewController {
    /// The project's files, for a chat that has a project and a server that can list a folder.
    /// Made the first time an `@` is typed, because most messages never need it.
    var mentionFinder: MentionFinder? {
        if let mentions { return mentions }
        guard let root = viewModel.session.directory, !root.isEmpty,
            let backend = viewModel.backend as? any FileBrowsingBackend
        else { return nil }
        let finder = MentionFinder(root: root, backend: backend)
        finder.note(git?.snapshot)
        finder.onChange = { [weak self] in self?.mentionsMoved() }
        mentions = finder
        return finder
    }

    var canFindFiles: Bool {
        viewModel.session.directory?.isEmpty == false && viewModel.backend is any FileBrowsingBackend
    }

    /// What the composer is told about this chat once, so its ink and its two keys are true: which
    /// slashes are commands here, which names are files, and whether there are files to find.
    func teachComposer() {
        composer.offersFileDoor = canFindFiles
        composer.knowsCommand = { [weak self] name in self?.isCommand(name) ?? false }
        composer.knowsPath = { [weak self] name in
            MentionToken.looksLikePath(name) || (self?.mentions?.shelf.holds(name) ?? false)
        }
    }

    /// A slash is inked as a command only when sending it would run one. Anything else goes out
    /// as the words it is, and is drawn as words.
    private func isCommand(_ name: String) -> Bool {
        SlashDispatch.decide(
            text: "/\(name)", commands: viewModel.composerCommands,
            supportsCompaction: viewModel.supportsCompaction,
            resolvesFromPromptText: viewModel.resolvesCommandsFromPromptText,
            supportsDesign: viewModel.supportsDesign, supportsDelegate: viewModel.supportsDelegate
        ) != .plainText
    }

    /// One list floats over the box, and what the caret is in decides whose it is: a file's name
    /// being typed after an `@`, or else whatever the slash at the front of the draft asks for.
    func updateComposerPalette(for text: String) {
        if let token = MentionToken.at(caret: composer.caretOffset, in: text), let finder = mentionFinder {
            mentionToken = token
            finder.watching = true
            presentMentions(token, from: finder)
            return
        }
        endMentions()
        updateCommandPalette(for: text)
    }

    func endMentions() {
        guard mentionToken != nil else { return }
        mentionToken = nil
        mentions?.watching = false
    }

    /// The caret walked into or out of a name without a letter being typed.
    func caretMoved() {
        let text = composer.rawText
        guard mentionToken != nil || text.contains("@") else { return }
        let token = mentions == nil && !canFindFiles
            ? nil : MentionToken.at(caret: composer.caretOffset, in: text)
        guard token != mentionToken else { return }
        updateComposerPalette(for: text)
    }

    private func mentionsMoved() {
        guard let token = mentionToken, let mentions else { return }
        presentMentions(token, from: mentions)
    }

    /// Rows when there are any. With none, the list says a folder is being read, and otherwise
    /// stays out of the way: letters that find nothing are most likely not a file at all.
    private func presentMentions(_ token: MentionToken, from finder: MentionFinder) {
        let answer = finder.shelf.answer(token.query)
        if let wanted = answer.wanted { finder.want(wanted) }
        let walking = token.query.contains("/")
        guard answer.isEmpty else {
            let sections = answer.sections.map { section in
                SlashCommandSection(
                    title: MentionWords.title(section.title),
                    commands: section.rows.map { mentionCommand($0, showsFolder: !walking) })
            }
            showFiles(sections, note: nil)
            return
        }
        if answer.wanted != nil || (finder.isLooking && finder.shelf.listedFolders == 0) {
            showFiles([], note: MentionWords.looking)
        } else {
            hideCommandPalette()
        }
    }

    private func showFiles(_ sections: [SlashCommandSection], note: String?) {
        commandPalette.update(with: .files(sections, note: note))
        showCommandPalette()
    }

    private func mentionCommand(_ row: MentionRow, showsFolder: Bool) -> SlashCommand {
        let entry = row.entry
        return SlashCommand(
            id: "file:\(entry.path)", keywords: [],
            title: entry.isDirectory ? "\(entry.name)/" : entry.name,
            subtitle: showsFolder ? entry.folder : "", symbol: MentionGlyph.symbol(for: entry),
            highlight: row.highlight, badge: row.changed ? MentionWords.changed : nil,
            runsOnServer: true
        ) { [weak self] in
            self?.acceptMention(entry)
        }
    }

    /// Writes the chosen path over the half-typed name. A folder leaves the caret after its slash
    /// and the list open on what is inside; a file leaves a space and the list is gone.
    private func acceptMention(_ entry: MentionEntry) {
        guard let token = mentionToken else { return }
        Theme.Haptics.selection()
        composer.replace(token.replaced(in: composer.rawText), with: MentionToken.completion(for: entry))
        MidgarLog.info("mention: chose \(entry.isDirectory ? "folder" : "file") depth=\(entry.depth)", category: .ui)
    }

    #if DEBUG
        /// Presses the n-th row of the file list, for a run with no finger.
        func stageAcceptMention(_ index: Int) {
            guard let token = mentionToken, let mentions else { return }
            let rows = mentions.shelf.answer(token.query).rows
            guard rows.indices.contains(index) else { return }
            acceptMention(rows[index].entry)
        }
    #endif
}

/// The glyph a file wears in the list, by what its name ends in.
enum MentionGlyph {
    static func symbol(for entry: MentionEntry) -> String {
        guard !entry.isDirectory else { return "folder" }
        let name = entry.name.lowercased()
        guard let dot = name.lastIndex(of: ".") else { return "doc" }
        switch String(name[name.index(after: dot)...]) {
        case "swift": return "swift"
        case "md", "markdown", "txt", "rst": return "doc.plaintext"
        case "json", "yml", "yaml", "toml", "plist", "xml", "lock": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "pdf": return "photo"
        case "sh", "bash", "zsh", "fish": return "terminal"
        default: return "doc"
        }
    }
}
