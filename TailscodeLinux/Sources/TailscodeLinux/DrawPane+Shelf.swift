import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension DrawPane {
    /// The shelf: what the machine has made merged with this session's pictures, newest first,
    /// the render in flight leading and wearing the sketch. It is the same view in the rail and in
    /// the strip; this wires it to the studio.
    func buildShelf() {
        let pane = Weak(self)
        shelf.thumbnail = { id in pane.value?.thumbnailBits(for: id) ?? 0 }
        shelf.onChoose = { id in pane.value?.choose(tile: id) }
        shelf.onRefresh = { Gtk.onMain { pane.value?.studio.library.refresh() } }
        shelf.onWant = { ids in
            Gtk.onMain { pane.value?.wantThumbnails(ids) }
        }
        shelf.dragPath = { id in pane.value?.dragPath(for: id) }
        shelf.onHover = { id in
            Gtk.onMain {
                guard let item = pane.value?.entry(for: id)?.item else { return }
                pane.value?.studio.library.prefetchOriginal(item)
            }
        }
        shelf.onMenu = { id, widget, x, y in
            guard let pane = pane.value else { return }
            pane.choose(tile: id)
            pane.presentTileMenu(for: id, on: widget, x: x, y: y)
        }
    }

    func entry(for id: String) -> StudioShelfEntry? {
        entries.first { $0.id == id }
    }

    /// Everything the shelf draws, from the studio: the merged entries, a tile for each, which
    /// one is on the stage, and the sentence a machine that cannot list says in place of a
    /// silent empty shelf.
    func refreshShelf() {
        let library = studio.library
        entries = StudioShelf.merge(
            session: slot.pictures, machine: library.items, inFlight: slot.isBusy)
        let selection = StudioShelf.selection(
            in: entries, keptID: studio.keptStage?.item.id,
            picturePath: studio.keptStage == nil ? slot.onStage?.path : nil)
        selectedTile = selection
        var sentence: String?
        if let failure = library.failure, library.items.isEmpty {
            sentence = failure.reason(machine: studio.endpoint.shortName)
        } else if library.items.isEmpty, entries.isEmpty {
            sentence = library.loading
                ? ImageGenLibraryWords.loading
                : "\(ImageGenLibraryWords.emptyTitle). \(ImageGenLibraryWords.emptyBody)"
        }
        shelf.describe(
            heading: ImageGenLibraryWords.heading(machine: studio.endpoint.shortName),
            count: library.items.isEmpty
                ? nil
                : ImageGenLibraryWords.line(count: library.items.count, staleSince: library.staleSince),
            note: sentence)
        shelf.update(tiles: entries.map(tile(for:)), selection: selection)
    }

    /// One tile's words: the picture's own, or the sketch's for the job, with the age and size
    /// the pointer finds on hover and the way out.
    private func tile(for entry: StudioShelfEntry) -> StudioTile {
        switch entry.source {
        case .inFlight:
            let step = studio.progress.flatMap { progress -> String? in
                guard let step = progress.step, let steps = progress.steps, steps > 0 else { return nil }
                return "\(min(step, steps))/\(steps)"
            }
            return StudioTile(
                id: entry.id, inFlight: true, badge: step, progress: studio.progress?.bar,
                glyph: "…", words: studio.progress?.line ?? slot.busyLine,
                tooltip: paintingSentence)
        case .session(let picture):
            let facts = ImageGenFacts.line(for: picture)
            return StudioTile(
                id: entry.id, words: StudioWords.shelfTileLabel(words: picture.prompt, facts: facts),
                tooltip: hoverLine(
                    age: picture.madeAt, bytes: Self.fileSize(picture.path)))
        case .machine(let item, let made):
            let facts = studio.library.facts[item.id]
            let words =
                made?.prompt ?? ImageGenFacts.caption(for: facts)
            let line = made.map { ImageGenFacts.line(for: $0) } ?? ImageGenFacts.line(for: facts)
            return StudioTile(
                id: entry.id, words: StudioWords.shelfTileLabel(words: words, facts: line),
                tooltip: hoverLine(age: facts?.modifiedAt ?? made?.madeAt, bytes: facts?.bytes))
        }
    }

    /// The age and size of a picture, and how to take it out of here — which is what hovering a
    /// tile is for.
    private func hoverLine(age: Date?, bytes: Int?) -> String {
        var parts: [String] = []
        if let age { parts.append(ImageGenLibraryWords.ago(age)) }
        if let bytes { parts.append(ImageGenFacts.size(bytes)) }
        parts.append(StudioWords.dragOutHint)
        return parts.joined(separator: " · ")
    }

    private static func fileSize(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
    }

    /// The decoded picture a tile draws, from whoever holds it: the sketch for the job, the
    /// machine's own thumbnail for one it kept — or, until that decodes, the copy this session
    /// already has — and this session's own decode for one the machine has not listed.
    func thumbnailBits(for id: String) -> UInt {
        guard let entry = entry(for: id) else { return 0 }
        switch entry.source {
        case .inFlight:
            return studio.previewTexture
        case .session(let picture):
            return textures[picture.path] ?? 0
        case .machine(let item, let made):
            if let bits = studio.library.textures[item.id], bits != 0 { return bits }
            return made.flatMap { textures[$0.path] } ?? 0
        }
    }

    /// The shelf says which tiles are near the eye; the library decodes exactly those thumbnails,
    /// and keeps the machine's newest for the stage's backdrop and whatever is on the stage.
    func wantThumbnails(_ ids: [String]) {
        var keep: Set<String> = []
        if let first = entries.first(where: { !$0.isInFlight })?.item { keep.insert(first.id) }
        if let kept = studio.keptStage { keep.insert(kept.item.id) }
        if let key = underwayKey { keep.insert(key) }
        let wanted = ids.compactMap { entry(for: $0)?.item?.id }
        studio.library.want(wanted, keeping: keep)
    }

    func updateJobTile() {
        guard let job = entries.first(where: { $0.isInFlight }) else { return }
        shelf.set(tile: tile(for: job))
    }

    /// Puts the tile's picture on the stage: the machine's own through the studio, which finds
    /// the session's copy when it is one this device made, and a session picture directly.
    func choose(tile id: String) {
        guard let entry = entry(for: id) else { return }
        selectedTile = id
        switch entry.source {
        case .inFlight:
            return
        case .session(let picture):
            studio.show(picture.path)
        case .machine(let item, _):
            studio.showKept(item)
        }
    }

    /// The local file behind a tile, for a drag out: the bytes as the machine wrote them, never a
    /// re-encode of the thumbnail. Nil until this device holds them, in which case the press stays
    /// a click and the original is already on its way from the pointer's rest on the tile.
    func dragPath(for id: String) -> String? {
        guard let entry = entry(for: id) else { return nil }
        if let item = entry.item, let held = studio.library.localOriginal(item) { return held }
        return entry.localPath
    }

    /// The verbs a tile offers on a right click: the picture goes on the stage first, and the
    /// verbs act on it as soon as its bytes are here.
    func presentTileMenu(
        for id: String, on widget: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        guard entry(for: id)?.isInFlight == false else { return }
        let pane = Weak(self)
        let rows = stageVerbsForMenu().map { verb -> (title: String, detail: String?, action: @Sendable () -> Void) in
            let action = verb.perform
            return (
                title: "\(verb.glyph)  \(verb.title)", detail: verb.hint,
                action: { Gtk.onMain { pane.value?.whenStageReady(action) } }
            )
        }
        Gtk.contextMenu(on: widget, x: x, y: y, rows: rows)
    }

    private func stageVerbsForMenu() -> [StudioVerb] {
        let actions = ImageGenAction.offered(
            kept: studio.keptStage != nil, hasWords: true, sharing: false, tapOpens: false)
        let pane = Weak(self)
        return actions.map { action in
            StudioVerb(
                id: action.rawValue, glyph: action.glyph, title: action.title, hint: action.hint,
                isDestructive: action.isDestructive, perform: { pane.value?.perform(action) })
        }
    }

    /// A verb on a picture the machine kept needs its bytes; they are on their way from the
    /// moment it was put on the stage, so the verb waits for them for a few seconds rather than
    /// doing nothing.
    private func whenStageReady(_ action: @escaping @Sendable () -> Void, attempts: Int = 20) {
        if stagePath != nil {
            action()
            return
        }
        guard attempts > 0 else { return }
        Gtk.after(300) { [weak self] in
            Gtk.onMain { [weak self] in self?.whenStageReady(action, attempts: attempts - 1) }
        }
    }

    /// The pill, from what the machine last answered — never from a guess.
    func refreshMachine() {
        machine.apply(
            StudioMachinePill.image(
                machine: studio.endpoint.shortName, sighting: studio.sighting, engine: slot.engine,
                painting: slot.isBusy))
    }
}
