import UIKit

@MainActor
final class LogViewerViewController: UIViewController {
    private let textView = UITextView()
    private var errorsOnly = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Logs"
        view.backgroundColor = Theme.Color.background
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self,
                action: #selector(share)),
            filterButton(),
            UIBarButtonItem(
                image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self,
                action: #selector(reload)),
        ]

        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.m, bottom: Theme.Spacing.m, right: Theme.Spacing.m)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reload()
    }

    private func filterButton() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(
                systemName: errorsOnly
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"),
            menu: UIMenu(children: [
                UIAction(title: "All entries", state: errorsOnly ? .off : .on) { [weak self] _ in
                    self?.errorsOnly = false
                    self?.refreshFilterUI()
                },
                UIAction(title: "Errors only", state: errorsOnly ? .on : .off) { [weak self] _ in
                    self?.errorsOnly = true
                    self?.refreshFilterUI()
                },
            ]))
    }

    private func refreshFilterUI() {
        navigationItem.rightBarButtonItems?[1] = filterButton()
        reload()
    }

    @objc private func reload() {
        let text = LogFileWriter.shared.snapshot()
        guard !text.isEmpty else {
            textView.text = "No log entries yet."
            textView.font = Theme.Font.mono(11)
            textView.textColor = Theme.Color.secondaryLabel
            return
        }
        textView.attributedText = Self.colorized(text, errorsOnly: errorsOnly)
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    private static func colorized(_ text: String, errorsOnly: Bool) -> NSAttributedString {
        let mono = Theme.Font.mono(11)
        let result = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let isError = line.contains("] ERROR ")
            if errorsOnly && !isError { continue }
            let string = String(line) + "\n"
            let attributed = NSMutableAttributedString(
                string: string,
                attributes: [
                    .font: mono,
                    .foregroundColor: isError ? Theme.Color.danger : Theme.Color.secondaryLabel,
                ])
            if !isError, let open = string.firstIndex(of: "["),
                let close = string.firstIndex(of: "]")
            {
                let range = NSRange(open...close, in: string)
                attributed.addAttribute(.foregroundColor, value: Theme.Color.accent, range: range)
            }
            result.append(attributed)
        }
        if result.length == 0 {
            return NSAttributedString(
                string: errorsOnly ? "No errors logged. 🎉" : "No log entries yet.",
                attributes: [.font: mono, .foregroundColor: Theme.Color.secondaryLabel])
        }
        return result
    }

    private func scrollToBottom() {
        let length = (textView.text as NSString).length
        guard length > 0 else { return }
        textView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
    }

    @objc private func share() {
        var items: [URL] = [LogFileWriter.shared.currentURL]
        let previous = LogFileWriter.shared.previousFileURL
        if FileManager.default.fileExists(atPath: previous.path) {
            items.append(previous)
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }
}
