import UIKit

@MainActor
final class LogViewerViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Logs"
        view.backgroundColor = Theme.Color.background
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self,
                action: #selector(share)),
            UIBarButtonItem(
                image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self,
                action: #selector(reload)),
        ]

        textView.isEditable = false
        textView.font = Theme.Font.mono(11)
        textView.textColor = Theme.Color.secondaryLabel
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

    @objc private func reload() {
        let text = LogFileWriter.shared.snapshot()
        textView.text = text.isEmpty ? "No log entries yet." : text
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
    }

    private func scrollToBottom() {
        guard textView.text.count > 0 else { return }
        let end = NSRange(location: textView.text.count - 1, length: 1)
        textView.scrollRangeToVisible(end)
    }

    @objc private func share() {
        let sheet = UIActivityViewController(
            activityItems: [LogFileWriter.shared.currentURL], applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }
}
