import TailscodeCore
import UIKit

/// Paints what `DraftInk` reads into a prompt box: a known command and a found file in the accent,
/// closed backticks in the mono face, and the power word in the aura's own rainbow. Only ink and
/// face change, never the words, so undo, autocorrection and the caret are left exactly as the
/// system keeps them.
@MainActor
final class ComposerInk {
    private weak var textView: UITextView?
    private var painted: [DraftInk.Run] = []
    /// The edits the box was told of since it was last painted. One is followed exactly; none
    /// (the words were set from outside) or several (marked text being composed) paint it whole.
    private var edits: [DraftInk.Edit] = []

    var knowsCommand: (String) -> Bool = { _ in false }
    var knowsPath: (String) -> Bool = MentionToken.looksLikePath

    init(textView: UITextView) {
        self.textView = textView
        Self.teachSpelling
    }

    /// The power word is a word here, so the system's spelling check is told once and stops
    /// underlining it in red beneath its rainbow.
    private static let teachSpelling: Void = {
        guard !UITextChecker.hasLearnedWord(Ultracode.effortLevel) else { return }
        UITextChecker.learnWord(Ultracode.effortLevel)
    }()

    static var base: [NSAttributedString.Key: Any] {
        [.font: Theme.Ramp.font(.answer), .foregroundColor: Theme.Color.label]
    }

    /// New letters are written in ordinary ink wherever the caret stands. A text view hands the
    /// next keystroke the attributes of the letter before it, which would let a painted word
    /// bleed into whatever is typed after it.
    func holdTypingInk() {
        guard !painted.isEmpty else { return }
        textView?.typingAttributes = Self.base
    }

    /// The box is about to take this edit, which is what lets the next paint touch only the ink
    /// the edit reached.
    func willEdit(_ range: NSRange, with text: String) {
        edits.append(
            DraftInk.Edit(location: range.location, removed: range.length, written: (text as NSString).length))
    }

    /// Repaints the draft. A draft with no runs, now or before, is never touched: most drafts
    /// are plain words and cost nothing here. After one edit only the runs it disturbed are
    /// repainted, because ink set across the whole draft lays every line of it out again.
    ///
    /// - Parameter force: the storage's attributes were replaced by someone else — a draft put
    ///   back, a dictated take landing, a change of type size or theme.
    func paint(force: Bool = false) {
        guard let textView, textView.markedTextRange == nil else { return }
        let told = edits
        edits = []
        let runs = DraftInk.read(
            textView.text ?? "", knowsCommand: knowsCommand, knowsPath: knowsPath)
        guard force || !runs.isEmpty || !painted.isEmpty else { return }
        let storage = textView.textStorage
        let length = storage.length
        let faces = currentFaces
        storage.beginEditing()
        if !force, told.count == 1, let edit = told.first, Self.fits(edit, painted: painted, length: length) {
            let plan = DraftInk.repaint(from: painted, to: runs, after: edit, length: length)
            for range in plan.clear {
                storage.setAttributes(faces.base, range: NSRange(location: range.lowerBound, length: range.count))
            }
            for run in plan.paint where run.end <= length { apply(run, to: storage, in: faces) }
        } else {
            storage.setAttributes(faces.base, range: NSRange(location: 0, length: length))
            for run in runs where run.end <= length { apply(run, to: storage, in: faces) }
        }
        storage.endEditing()
        textView.typingAttributes = faces.base
        painted = runs
    }

    /// Whether the edit can be what turned the painted draft into the one in the box: it lies
    /// inside the old words and leaves exactly the length the box now has.
    private static func fits(_ edit: DraftInk.Edit, painted: [DraftInk.Run], length: Int) -> Bool {
        let before = length - edit.written + edit.removed
        return edit.location >= 0 && edit.location + edit.removed <= before
            && (painted.last?.end ?? 0) <= before
    }

    private func apply(_ run: DraftInk.Run, to storage: NSTextStorage, in faces: Faces) {
        let range = NSRange(location: run.start, length: run.length)
        switch run.kind {
        case .command:
            storage.addAttributes([.foregroundColor: Theme.Color.accent, .font: faces.strong], range: range)
        case .mention:
            storage.addAttribute(.foregroundColor, value: Theme.Color.accent, range: range)
        case .code:
            storage.addAttributes([.font: faces.mono, .backgroundColor: faces.codeWash], range: range)
        case .power:
            storage.addAttribute(.font, value: faces.strong, range: range)
            for offset in 0..<run.length {
                storage.addAttribute(
                    .foregroundColor, value: Theme.Color.modelRainbowLetter(offset, of: run.length),
                    range: NSRange(location: run.start + offset, length: 1))
            }
        }
    }

    /// The faces ink is drawn in, made once for each type size rather than on every key. Colours
    /// are read fresh each time, because a theme changes them without changing the size.
    private struct Faces {
        let answer: UIFont
        let strong: UIFont
        let mono: UIFont
        let base: [NSAttributedString.Key: Any]
        let codeWash: UIColor
    }

    private var fonts: (answer: UIFont, strong: UIFont, mono: UIFont)?

    private var currentFaces: Faces {
        let answer = Theme.Ramp.font(.answer)
        let kept: (answer: UIFont, strong: UIFont, mono: UIFont)
        if let fonts, fonts.answer === answer {
            kept = fonts
        } else {
            let descriptor = answer.fontDescriptor.withSymbolicTraits(.traitBold) ?? answer.fontDescriptor
            kept = (
                answer, UIFont(descriptor: descriptor, size: answer.pointSize),
                Theme.Font.mono((answer.pointSize * 0.93).rounded())
            )
            fonts = kept
        }
        return Faces(
            answer: answer, strong: kept.strong, mono: kept.mono, base: Self.base,
            codeWash: Theme.Color.label.withAlphaComponent(0.09))
    }
}
