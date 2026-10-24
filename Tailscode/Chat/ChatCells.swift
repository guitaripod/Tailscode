import CodingAgentKit
import TailscodeCore
import UIKit

@MainActor
protocol TextBubbleCellDelegate: AnyObject {
    func textBubbleCell(_ cell: TextBubbleCell, didTapLink url: URL)
}

struct ChatRow: Hashable {
    let id: String
    let messageID: String
    let role: MessageRole
    let content: Content

    enum Content: Hashable {
        case text(String)
        case code(CodeBlock)
        case table(MarkdownTable)
        /// A table still being written: its card, its count, and none of its rows measured.
        case tableDraft(TableDraft)
        case activity([ActivityStep])
        /// Everything one turn did before its answer, drawn as one head.
        case brain(BrainRow)
        case subagent(SubagentCard)
        case workflow(WorkflowRun)
        case subagentGroup(SubagentGroup)
        case compaction(CompactionRow)
        /// Where the answering model changed, as one flat line before the answer it changed on.
        case modelSeam(ModelSwitch)
        /// The first row of a chat that was carried from another: where it came from.
        case carried(CarryReading)
        case taskBoard(TaskBoard)
        /// A board of design alternatives the agent wrote, standing where the manifest that made
        /// it was written rather than as a line about a file.
        case designBoard(DesignSighting)
        case file(FileReference)
        case image(FileReference)
        case timestamp(String)
        case failed(FailedTurn)
        case answerless(AnswerlessTurn)
        /// What the server wrote for the reader rather than the model: a quiet line, never a
        /// message, standing between the turns it separates.
        case note(TranscriptNoteLine)
        /// What the answer above it took, drawn only where the reader asked for it.
        case responseStats(ResponseStats)
        /// The addresses a run of prose mentioned, as one line docked where the run closes.
        case linkRail(LinkRailRun)
        /// Consecutive pictures the agent made, sharing one wrapping row.
        case pictures([FileReference])
    }
}

/// What a link rail is made of: the addresses of one settled prose run, in the order written. The
/// rail's open state and what the network has said about each page are the cell's and the store's,
/// so a fetch landing or a tap never makes the row a different value.
struct LinkRailRun: Hashable {
    let addresses: [String]
}

enum ActivityStep: Hashable {
    case reasoning(String)
    case tool(ToolCall)
}

struct CodeBlock: Hashable {
    let language: String?
    let source: String
}

extension MessageSegment {
    /// The shared splitter's rows in this client's grammar, so every consumer maps a segment the
    /// same way.
    var chatContent: ChatRow.Content {
        switch self {
        case .prose(let text):
            return .text(text)
        case .code(let language, let body):
            return .code(CodeBlock(language: language, source: body))
        case .table(let table):
            return .table(table)
        }
    }
}

/// A rule drawn as the width of whatever line holds it. It asks the layout for the line's width
/// each time the line is laid out, so a window that changes width or a type size that changes the
/// line height never leaves it short or wrapped.
final class HairlineAttachment: NSTextAttachment {
    private let height: CGFloat = 1
    private let lift: CGFloat

    init(font: UIFont) {
        lift = (font.capHeight - height) / 2
        super.init(data: nil, ofType: nil)
        image = Self.solid
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static let solid: UIImage = {
        let size = CGSize(width: 2, height: 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }()

    override func attachmentBounds(
        for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint, characterIndex charIndex: Int
    ) -> CGRect {
        let padding = (textContainer?.lineFragmentPadding ?? 0) * 2
        return CGRect(x: 0, y: lift, width: max(0, lineFrag.width - padding), height: height)
    }
}

/// A bubble that places its words by frame when asked to, so a row that measures itself is not also
/// solved for by the constraint engine.
final class BubbleView: UIView {
    var placedContent: UIView?
    var contentInsets: UIEdgeInsets = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let placedContent else { return }
        let target = bounds.inset(by: contentInsets)
        if placedContent.frame != target { placedContent.frame = target }
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Digits of one width, for anything that changes while a person is looking at it.
    func monospacedDigits() -> UIFont {
        let settings: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kNumberSpacingType, .selector: kMonospacedNumbersSelector,
        ]
        return UIFont(
            descriptor: fontDescriptor.addingAttributes([.featureSettings: [settings]]), size: 0)
    }
}
