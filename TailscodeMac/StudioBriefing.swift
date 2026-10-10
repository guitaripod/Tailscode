import AppKit
import ImageIO
import TailscodeCore

/// The helper that writes a better paragraph for the words, as the dock and its rewrite card see
/// it: one asker for both lanes, because the helper is filed once for the device and the card, the
/// picker and the four things to do with a rewrite are the same control whichever lane wrote the
/// ask. A lane only decides what the helper is told about the thing being made.
@MainActor
protocol StudioWriting: AnyObject {
    var draft: ImageGenRewriteDraft? { get }
    var enhancing: Bool { get }
    var helper: ImageGenHelper? { get }
    var helperServers: [ImageGenHelperServer] { get }
    var surveying: Bool { get }
    func enhance(_ brief: String, instruction: String?)
    func dismissRewrite()
    func surveyHelpers()
    func setHelper(_ helper: ImageGenHelper?)
    func toggleHelper()
}

extension StudioWriting {
    func enhance(_ brief: String) { enhance(brief, instruction: nil) }
}

/// A decision that is a line of words — what to keep out, what is heard — asked for in a small
/// popover over the pill that opened it.
struct StudioWordsField {
    let title: String
    let hint: String
    let placeholder: String
    let current: String
    let apply: @MainActor (String) -> Void
}

/// The picture a lane starts from, as the 56-point slot draws it: what it is called, what it
/// promises, and how to get a small copy of it — a picture on disk, one the machine keeps, or the
/// poster of the clip it continues.
struct StudioStartHold {
    let id: String
    let name: String
    let tooltip: String
    let thumbnail: @MainActor () async -> CGImage?
}

/// The brief the dock edits, as a lane describes it. The dock is one control for both lanes — the
/// words, the pills, Enhance, the start slot, the estimate and Go — and everything that differs
/// between a picture and a clip comes through here: which pills there are and what each opens, what
/// the start slot holds, what Go asks for and what a drop means.
@MainActor
protocol StudioBriefing: StudioWriting {
    var wordsPlaceholder: String { get }
    var goTitle: String { get }
    var draftWords: String { get }
    var isBusy: Bool { get }
    var estimateLine: String { get }
    var noticeHandler: ((String) -> Void)? { get set }
    var library: MacImageLibrary { get }
    var startHold: StudioStartHold? { get }
    var startEmptyTitle: String { get }
    var startEmptyHint: String { get }

    func rememberDraft(_ words: String)
    func submit(prompt: String)
    func stop()
    func followWriter(aspect: ImageGenAspect?)
    func chips() -> [StudioChip]
    func toggle(_ chip: StudioChip)
    func menu(for chip: StudioChip, gallery: @escaping @MainActor () -> Void) -> NSMenu?
    func wordsField(for chip: StudioChip) -> StudioWordsField?
    func fillStartMenu(_ menu: NSMenu, gallery: @escaping @MainActor () -> Void)
    func releaseStart()
    func hold(drop: StudioDrop, then done: @escaping @MainActor (Bool) -> Void)
    func hold(gallery item: ImageGenLibraryItem)
    func watchLibrary(_ owner: AnyObject, _ block: @escaping @MainActor () -> Void)
    func unwatchLibrary(_ owner: AnyObject)
}

extension MacImageStudio: StudioBriefing {
    var wordsPlaceholder: String { Localized.text("Describe a picture, or drop one here to edit") }

    var goTitle: String { ImageGenWords.renderTitle(mode: .generate) }

    var draftWords: String { slot.promptDraft }

    var isBusy: Bool { isPainting }

    var startEmptyTitle: String { ImageGenWords.attachTitle }

    var startEmptyHint: String { ImageGenWords.attachHint }

    var startHold: StudioStartHold? {
        guard let held = slot.reference else { return nil }
        let path = held.path.isEmpty ? (held.kept.flatMap { library.thumbnailPath(of: $0) } ?? "") : held.path
        return StudioStartHold(
            id: path, name: held.name, tooltip: ImageGenWords.referenceHint(held),
            thumbnail: {
                guard !path.isEmpty else { return nil }
                return await Task.detached {
                    FileManager.default.contents(atPath: path).flatMap {
                        MacImageLibrary.downsample($0, longestSide: 160)
                    }
                }.value
            })
    }

    func chips() -> [StudioChip] {
        StudioChips.read(slot: slot, engineBlocked: engineBlocked != nil)
    }

    func toggle(_ chip: StudioChip) {
        if chip.kind == .cutout { setCutout(!slot.cutout) }
    }

    func menu(for chip: StudioChip, gallery: @escaping @MainActor () -> Void) -> NSMenu? {
        StudioChipMenu.menu(for: chip.kind, studio: self, library: gallery)
    }

    func wordsField(for chip: StudioChip) -> StudioWordsField? {
        guard chip.kind == .avoid else { return nil }
        return StudioWordsField(
            title: ImageGenWords.avoidTitle, hint: ImageGenWords.avoidHint,
            placeholder: ImageGenWords.avoidPlaceholder, current: slot.negative
        ) { [weak self] words in self?.setNegative(words) }
    }

    func fillStartMenu(_ menu: NSMenu, gallery: @escaping @MainActor () -> Void) {
        StudioReferenceMenu.fill(menu, studio: self, library: gallery)
    }

    func releaseStart() { hold(nil) }

    func hold(drop: StudioDrop, then done: @escaping @MainActor (Bool) -> Void) {
        StudioDrop.hold(drop, in: self, then: done)
    }

    func hold(gallery item: ImageGenLibraryItem) { hold(kept: item) }

    func watchLibrary(_ owner: AnyObject, _ block: @escaping @MainActor () -> Void) {
        watch(owner) { change in
            if case .shelf = change { block() }
        }
    }

    func unwatchLibrary(_ owner: AnyObject) { unwatch(owner) }
}
