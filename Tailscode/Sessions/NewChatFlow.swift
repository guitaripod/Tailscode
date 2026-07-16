import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The one way a chat starts anywhere in the app: pick the project directory
/// with the server's file browser when the backend can list files, fall back
/// to a typed path, create the session, and hand the entry back.
@MainActor
enum NewChatFlow {
    static func begin(
        from presenter: UIViewController,
        profile: ConnectionProfile,
        viewModel: SessionListViewModel,
        onOpen: @escaping (SessionEntry) -> Void
    ) {
        guard let backend = viewModel.backend(forProfileID: profile.id),
            let fileBackend = backend as? (any FileBrowsingBackend),
            backend.capabilities.supportsFileBrowsing
        else {
            promptForPath(from: presenter, profile: profile, viewModel: viewModel, onOpen: onOpen)
            return
        }
        let browser = FileBrowserViewController(backend: fileBackend, profileID: profile.id)
        browser.onSelect = { [weak presenter] path in
            guard let presenter else { return }
            presenter.presentedViewController?.dismiss(animated: true) {
                Task {
                    guard let entry = await viewModel.newSession(on: profile, directory: path)
                    else { return }
                    onOpen(entry)
                }
            }
        }
        presenter.present(UINavigationController(rootViewController: browser), animated: true)
    }

    private static func promptForPath(
        from presenter: UIViewController,
        profile: ConnectionProfile,
        viewModel: SessionListViewModel,
        onOpen: @escaping (SessionEntry) -> Void
    ) {
        let alert = UIAlertController(
            title: "New Chat",
            message: "Enter a directory path on the server",
            preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "/path/to/project"
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak alert] _ in
            let trimmed = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let directory = trimmed?.isEmpty == false ? trimmed : nil
            Task {
                guard let entry = await viewModel.newSession(on: profile, directory: directory)
                else { return }
                onOpen(entry)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
