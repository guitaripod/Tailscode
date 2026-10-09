import CodingAgentKit
import TailscodeCore
import UIKit

/// The second page of a conversation held open like a book: the page across the fold from the
/// transcript, where a tool's whole output, a table at its natural width and the repository's state
/// are read without leaving the conversation or covering it with a sheet.
@MainActor
final class ChatInspector {
    let navigation = UINavigationController()
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?

    var isInstalled: Bool { navigation.parent != nil }

    /// - Parameters:
    ///   - leadingEdge: where the page begins, the far side of the fold.
    ///   - trailingInset: what the system keeps at the far edge for its bar, which the page stops
    ///     short of so the bar's buttons stay where a thumb expects them.
    func install(
        in parent: UIViewController, leadingEdge: CGFloat, trailingInset: CGFloat,
        root: () -> UIViewController
    ) {
        if isInstalled {
            leading?.constant = leadingEdge
            trailing?.constant = -trailingInset
            return
        }
        navigation.setViewControllers([root()], animated: false)
        parent.addChild(navigation)
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(navigation.view)
        let edge = navigation.view.leadingAnchor.constraint(
            equalTo: parent.view.leadingAnchor, constant: leadingEdge)
        let far = navigation.view.trailingAnchor.constraint(
            equalTo: parent.view.trailingAnchor, constant: -trailingInset)
        leading = edge
        trailing = far
        NSLayoutConstraint.activate([
            edge, far,
            navigation.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor),
        ])
        navigation.didMove(toParent: parent)
    }

    func uninstall() {
        guard isInstalled else { return }
        navigation.willMove(toParent: nil)
        navigation.view.removeFromSuperview()
        navigation.removeFromParent()
        leading = nil
        trailing = nil
    }

    func show(_ controller: UIViewController) {
        navigation.setViewControllers([controller], animated: false)
    }

    static func placeholder() -> UIViewController {
        let controller = InspectorPlaceholderViewController()
        return controller
    }
}

/// What the second page shows before anything is sent to it: a picture and no words, so there is
/// nothing to translate and nothing to read past.
final class InspectorPlaceholderViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "doc.text.magnifyingglass")
        configuration.imageProperties.tintColor = Theme.Color.tertiaryLabel
        contentUnavailableConfiguration = configuration
    }
}

/// One tool call's command and its whole output, as plain selectable text at a size that reads.
final class ToolOutputViewController: UIViewController {
    private let call: ToolCall
    private let textView = UITextView()

    init(call: ToolCall) {
        self.call = call
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = call.summary.title ?? call.name
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.l, bottom: Theme.Spacing.l,
            right: Theme.Spacing.l)
        textView.attributedText = Self.body(of: call)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    private static func body(of call: ToolCall) -> NSAttributedString {
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let text = NSMutableAttributedString()
        if let command = call.summary.command {
            text.append(
                NSAttributedString(
                    string: command + "\n\n",
                    attributes: [
                        .font: UIFontMetrics(forTextStyle: .footnote).scaledFont(
                            for: .monospacedSystemFont(ofSize: 13, weight: .semibold)),
                        .foregroundColor: Theme.Color.label,
                    ]))
        }
        text.append(
            NSAttributedString(
                string: call.output ?? "",
                attributes: [.font: font, .foregroundColor: Theme.Color.secondaryLabel]))
        return text
    }
}

/// A table at its natural width, scrolling both ways, on the page a reader keeps open beside the
/// conversation that wrote it.
final class TableInspectorViewController: UIViewController {
    private let table: MarkdownTable

    init(table: MarkdownTable) {
        self.table = table
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let card = TableCell.tableView(table)
        card.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(card)
        let content = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            card.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.m),
            card.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Spacing.l),
            card.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }
}
