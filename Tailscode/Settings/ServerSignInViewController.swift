import CodingAgentKit
import CodingAgentKitApple
import SafariServices
import UIKit

/// Signing a server's Claude Code back in, from the phone.
///
/// A signed-out CLI does not fail a turn — it answers it, with "Not logged in · Please run
/// /login", which is a sentence no one should have to interpret. And the fix has always lived in a
/// terminal on the other machine, which is exactly where the person holding the phone is not.
///
/// The sign-in is an ordinary browser flow with the two ends split across two machines: the server
/// starts it and hands over the link, this screen opens the link and takes the code back. So it
/// reads as two steps, and nothing is asked for before it is needed.
@MainActor
final class ServerSignInViewController: UIViewController {
    var onSignedIn: ((ServerAuth) -> Void)?

    private enum Step {
        case starting
        case awaitingCode(url: URL)
        case submitting
        case signedIn(ServerAuth)
        case failed(String)
    }

    private let profile: ConnectionProfile
    private let backend: any AuthenticatingBackend
    private var step: Step = .starting {
        didSet { render() }
    }

    private let scroll = UIScrollView()
    private let column = UIStackView()
    private let badge = UIImageView()
    private let headline = UILabel()
    private let detail = UILabel()
    private let stepOne = StepCard(
        number: 1, title: String(localized: "Open the Claude sign-in page"),
        detail: String(
            localized: "It opens here. Sign in with your Anthropic account and it hands you a code."
        ))
    private let stepTwo = StepCard(
        number: 2, title: String(localized: "Paste the code back"),
        detail: String(localized: "That is what signs the machine in. Nothing is stored on this phone."))
    private let codeField = UITextField()
    private let action = PrimaryButton(title: String(localized: "Open the sign-in page"))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    init(profile: ConnectionProfile, backend: any AuthenticatingBackend) {
        self.profile = profile
        self.backend = backend
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Sign in")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismissSelf() })
        buildUI()
        render()
        NotificationCenter.default.addObserver(
            self, selector: #selector(returnedToApp),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        Task { await begin() }
    }

    /// The code lands on the pasteboard while the browser is still open, so coming back to a
    /// prefilled field is the shortest honest version of this step.
    @objc private func returnedToApp() {
        guard case .awaitingCode = step, codeField.text?.isEmpty != false else { return }
        guard UIPasteboard.general.hasStrings, let pasted = UIPasteboard.general.string else {
            return
        }
        guard Self.looksLikeCode(pasted) else { return }
        codeField.text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        render()
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 20, trimmed.count < 400, !trimmed.contains(" ") else { return false }
        return !trimmed.hasPrefix("http")
    }

    private func begin() async {
        step = .starting
        do {
            let status = try await backend.beginSignIn()
            if status.loggedIn {
                step = .signedIn(status)
                return
            }
            guard let link = status.pending?.url, let url = URL(string: link) else {
                step = .failed(String(localized: "The server didn't hand back a sign-in link."))
                return
            }
            step = .awaitingCode(url: url)
        } catch AgentError.http(let code, _) where code == 404 {
            step = .failed(
                String(
                    localized:
                        "This server is too old to sign in from here. Update it, or run claude auth login on the machine."
                ))
        } catch {
            step = .failed(Self.message(for: error))
        }
    }

    private func submit() async {
        let code = (codeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        codeField.resignFirstResponder()
        step = .submitting
        do {
            let status = try await backend.submitSignInCode(code)
            Theme.Haptics.success()
            step = .signedIn(status)
            onSignedIn?(status)
        } catch {
            Theme.Haptics.warning()
            step = .failed(Self.message(for: error))
        }
    }

    private static func message(for error: any Error) -> String {
        if case AgentError.http(_, let body) = error, !body.isEmpty {
            if let data = body.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["error"] as? String
            {
                return message
            }
            return body
        }
        return error.localizedDescription
    }

    private func openLink(_ url: URL) {
        Theme.Haptics.tap()
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = Theme.Color.accent
        present(safari, animated: true)
    }

    private func dismissSelf() {
        if case .signedIn = step {} else { Task { try? await backend.cancelSignIn() } }
        dismiss(animated: true)
    }

    private func render() {
        switch step {
        case .starting:
            badge.image = UIImage(systemName: "person.badge.key")
            badge.tintColor = Theme.Color.accent
            headline.text = String(localized: "Sign in to Claude on \(profile.name)")
            detail.text = String(
                localized:
                    "Claude Code on that machine is signed out, so it can't answer anything. Signing in here signs the machine in.")
            stepOne.setState(.waiting)
            stepTwo.setState(.waiting)
            codeField.isHidden = true
            action.isHidden = true
            spinner.startAnimating()
            statusLabel.text = String(localized: "Asking the server for a link…")
            statusLabel.isHidden = false
        case .awaitingCode:
            badge.image = UIImage(systemName: "person.badge.key")
            badge.tintColor = Theme.Color.accent
            headline.text = String(localized: "Sign in to Claude on \(profile.name)")
            detail.text = String(
                localized:
                    "Claude Code on that machine is signed out, so it can't answer anything. Signing in here signs the machine in.")
            stepOne.setState(.active)
            stepTwo.setState(codeField.text?.isEmpty == false ? .active : .waiting)
            codeField.isHidden = false
            action.isHidden = false
            action.setTitle(
                codeField.text?.isEmpty == false
                    ? String(localized: "Finish signing in")
                    : String(localized: "Open the sign-in page"))
            spinner.stopAnimating()
            statusLabel.isHidden = true
        case .submitting:
            stepOne.setState(.done)
            stepTwo.setState(.active)
            codeField.isHidden = false
            action.isHidden = true
            spinner.startAnimating()
            statusLabel.text = String(localized: "Signing the machine in…")
            statusLabel.isHidden = false
        case .signedIn(let status):
            badge.image = UIImage(systemName: "checkmark.seal.fill")
            badge.tintColor = Theme.Color.success
            headline.text = String(localized: "\(profile.name) is signed in")
            detail.text =
                status.accountLabel.map { account in
                    status.subscription.map { plan in
                        String(localized: "\(account) · \(plan.capitalized) plan")
                    } ?? account
                } ?? String(localized: "Claude Code can answer again.")
            stepOne.setState(.done)
            stepTwo.setState(.done)
            codeField.isHidden = true
            action.isHidden = false
            action.setTitle(String(localized: "Done"))
            spinner.stopAnimating()
            statusLabel.isHidden = true
        case .failed(let reason):
            badge.image = UIImage(systemName: "exclamationmark.triangle.fill")
            badge.tintColor = Theme.Color.warning
            headline.text = String(localized: "That didn't sign in")
            detail.text = reason
            stepOne.setState(.waiting)
            stepTwo.setState(.waiting)
            codeField.isHidden = true
            action.isHidden = false
            action.setTitle(String(localized: "Start over"))
            spinner.stopAnimating()
            statusLabel.isHidden = true
        }
    }

    private func actionTapped() {
        switch step {
        case .awaitingCode(let url):
            if codeField.text?.isEmpty == false {
                Task { await submit() }
            } else {
                openLink(url)
            }
        case .signedIn:
            dismiss(animated: true)
        case .failed:
            codeField.text = nil
            Task { await begin() }
        case .starting, .submitting:
            break
        }
    }

    private func buildUI() {
        badge.contentMode = .scaleAspectFit
        badge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 44, weight: .semibold)
        badge.setContentHuggingPriority(.required, for: .vertical)

        headline.font = Theme.Font.display(.title2)
        headline.adjustsFontForContentSizeCategory = true
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 0

        detail.font = Theme.Font.subheadline()
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0

        codeField.placeholder = String(localized: "Paste the code")
        codeField.font = Theme.Font.mono(15)
        codeField.adjustsFontForContentSizeCategory = true
        codeField.borderStyle = .roundedRect
        codeField.autocorrectionType = .no
        codeField.autocapitalizationType = .none
        codeField.spellCheckingType = .no
        codeField.clearButtonMode = .whileEditing
        codeField.returnKeyType = .go
        codeField.delegate = self
        codeField.addAction(UIAction { [weak self] _ in self?.render() }, for: .editingChanged)
        codeField.heightAnchor.constraint(equalToConstant: 46).isActive = true

        action.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .touchUpInside)

        statusLabel.font = Theme.Font.footnote()
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = Theme.Color.secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        let progress = UIStackView(arrangedSubviews: [spinner, statusLabel])
        progress.axis = .horizontal
        progress.spacing = Theme.Spacing.s
        progress.alignment = .center

        column.axis = .vertical
        column.spacing = Theme.Spacing.l
        [badge, headline, detail, stepOne, stepTwo, codeField, action, progress].forEach(
            column.addArrangedSubview)
        column.setCustomSpacing(Theme.Spacing.l, after: badge)
        column.setCustomSpacing(Theme.Spacing.s, after: headline)
        column.setCustomSpacing(Theme.Spacing.xl, after: detail)
        column.setCustomSpacing(Theme.Spacing.m, after: stepOne)
        column.setCustomSpacing(Theme.Spacing.l, after: stepTwo)
        column.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.addSubview(column)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            column.topAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            column.widthAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Spacing.l),
        ])
    }
}

extension ServerSignInViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        Task { await submit() }
        return true
    }
}

/// One numbered step of the sign-in, which dims until it is this step's turn and ticks when it is
/// done — the same shape as the first-run checklist, because it is the same kind of promise.
private final class StepCard: UIView {
    enum State {
        case waiting
        case active
        case done
    }

    private let marker = UILabel()
    private let tick = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private let title = UILabel()
    private let detail = UILabel()

    init(number: Int, title titleText: String, detail detailText: String) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.secondaryBackground
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        marker.text = "\(number)"
        marker.font = Theme.Font.headline()
        marker.textAlignment = .center
        marker.textColor = .white
        marker.backgroundColor = Theme.Color.accent
        marker.layer.cornerRadius = 13
        marker.clipsToBounds = true
        marker.translatesAutoresizingMaskIntoConstraints = false

        tick.tintColor = Theme.Color.success
        tick.contentMode = .scaleAspectFit
        tick.isHidden = true
        tick.translatesAutoresizingMaskIntoConstraints = false

        title.text = titleText
        title.font = Theme.Font.headline()
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Theme.Color.label
        title.numberOfLines = 0

        detail.text = detailText
        detail.font = Theme.Font.footnote()
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = Theme.Spacing.xs
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(marker)
        addSubview(tick)
        addSubview(text)
        NSLayoutConstraint.activate([
            marker.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            marker.widthAnchor.constraint(equalToConstant: 26),
            marker.heightAnchor.constraint(equalToConstant: 26),
            tick.centerXAnchor.constraint(equalTo: marker.centerXAnchor),
            tick.centerYAnchor.constraint(equalTo: marker.centerYAnchor),
            tick.widthAnchor.constraint(equalToConstant: 26),
            tick.heightAnchor.constraint(equalToConstant: 26),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            text.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: Theme.Spacing.m),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setState(_ state: State) {
        switch state {
        case .waiting:
            alpha = 0.55
            marker.isHidden = false
            marker.backgroundColor = Theme.Color.tertiaryLabel
            tick.isHidden = true
        case .active:
            alpha = 1
            marker.isHidden = false
            marker.backgroundColor = Theme.Color.accent
            tick.isHidden = true
        case .done:
            alpha = 1
            marker.isHidden = true
            tick.isHidden = false
        }
    }
}
