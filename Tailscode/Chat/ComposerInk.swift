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

    /// Repaints the draft. A draft with no runs, now or before, is never touched: most drafts
    /// are plain words and cost nothing here.
    ///
    /// - Parameter force: the storage's attributes were replaced by someone else — a draft put
    ///   back, a dictated take landing, a change of type size or theme.
    func paint(force: Bool = false) {
        guard let textView, textView.markedTextRange == nil else { return }
        let runs = DraftInk.read(
            textView.text ?? "", knowsCommand: knowsCommand, knowsPath: knowsPath)
        guard force || !runs.isEmpty || !painted.isEmpty else { return }
        let storage = textView.textStorage
        let length = storage.length
        storage.beginEditing()
        storage.setAttributes(Self.base, range: NSRange(location: 0, length: length))
        for run in runs where run.end <= length {
            let range = NSRange(location: run.start, length: run.length)
            switch run.kind {
            case .command:
                storage.addAttributes(
                    [.foregroundColor: Theme.Color.accent, .font: Self.strong], range: range)
            case .mention:
                storage.addAttribute(.foregroundColor, value: Theme.Color.accent, range: range)
            case .code:
                storage.addAttributes(
                    [.font: Self.mono, .backgroundColor: Theme.Color.label.withAlphaComponent(0.09)],
                    range: range)
            case .power:
                storage.addAttribute(.font, value: Self.strong, range: range)
                for offset in 0..<run.length {
                    storage.addAttribute(
                        .foregroundColor, value: Theme.Color.modelRainbowLetter(offset, of: run.length),
                        range: NSRange(location: run.start + offset, length: 1))
                }
            }
        }
        storage.endEditing()
        textView.typingAttributes = Self.base
        painted = runs
    }

    private static var strong: UIFont {
        let base = Theme.Ramp.font(.answer)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static var mono: UIFont {
        Theme.Font.mono((Theme.Ramp.font(.answer).pointSize * 0.93).rounded())
    }
}
