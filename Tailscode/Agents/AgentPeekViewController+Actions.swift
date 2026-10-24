import MidgarCore
import TailscodeCore
import UIKit

extension AgentPeekViewController {
    func updateButtons() {
        let running = facts?.isRunning == true
        let away = row?.isAway == true
        secondaryRow.isHidden = !running
        stopButton.isEnabled = running && !away && !isBusy
        nudgeButton.isEnabled = running && !away && !isBusy
        openButton.isEnabled = true
        secondaryRow.axis = AgentsLayout.isLarge(traitCollection) ? .vertical : .horizontal
        if !running { hideNudge() }
        updateSend()
    }

    func requestWatch() {
        guard !watchRequested else { return }
        watchRequested = true
        Theme.Haptics.tap()
        hub.watch(target.key)
        render()
    }

    func confirmStop() {
        let alert = UIAlertController(
            title: String(localized: "Stop “\(target.title)”?"),
            message: String(localized: "The agent ends the turn it is on."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Stop"), style: .destructive) { [weak self] _ in
                self?.performStop()
            })
        present(alert, animated: true)
    }

    private func performStop() {
        guard !isBusy else { return }
        isBusy = true
        render()
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.hub.stop(self.target.key)
            self.isBusy = false
            switch reply {
            case .sent:
                Theme.Haptics.success()
                self.say(String(localized: "Stop sent"))
            case .needsChat:
                self.openChat()
            case .failed(let why):
                Theme.Haptics.error()
                MidgarLog.error("agent stop failed", category: .session)
                self.say(why, failure: true)
            }
            self.render()
        }
    }

    func buildNudgeBar() {
        nudgeBar.backgroundColor = Theme.Color.groupedSurface
        nudgeBar.isHidden = true
        nudgeBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nudgeBar)

        nudgeField.placeholder = String(localized: "Nudge this agent")
        nudgeField.font = Theme.Ramp.font(.composer)
        nudgeField.adjustsFontForContentSizeCategory = true
        nudgeField.returnKeyType = .send
        nudgeField.enablesReturnKeyAutomatically = true
        nudgeField.autocapitalizationType = .sentences
        nudgeField.borderStyle = .none
        nudgeField.accessibilityLabel = String(localized: "Nudge this agent")
        nudgeField.delegate = self
        nudgeField.addAction(
            UIAction { [weak self] _ in self?.updateSend() }, for: .editingChanged)

        var send = UIButton.Configuration.plain()
        send.image = UIImage(
            systemName: "arrow.up.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular))
        send.baseForegroundColor = Theme.Color.accent
        nudgeSend.configuration = send
        nudgeSend.accessibilityLabel = String(localized: "Send nudge")
        nudgeSend.setContentHuggingPriority(.required, for: .horizontal)
        nudgeSend.addAction(UIAction { [weak self] _ in self?.sendNudge() }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [nudgeField, nudgeSend])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        nudgeBar.addSubview(row)
        let hairline = UIView()
        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        nudgeBar.addSubview(hairline)
        NSLayoutConstraint.activate([
            nudgeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nudgeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nudgeBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            row.topAnchor.constraint(equalTo: nudgeBar.topAnchor, constant: Theme.Spacing.s),
            row.bottomAnchor.constraint(equalTo: nudgeBar.bottomAnchor, constant: -Theme.Spacing.s),
            row.leadingAnchor.constraint(equalTo: nudgeBar.leadingAnchor, constant: Theme.Spacing.l + 4),
            row.trailingAnchor.constraint(equalTo: nudgeBar.trailingAnchor, constant: -Theme.Spacing.m),
            hairline.topAnchor.constraint(equalTo: nudgeBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: nudgeBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: nudgeBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    func showNudge() {
        guard nudgeButton.isEnabled else { return }
        nudgeBar.isHidden = false
        nudgeField.becomeFirstResponder()
        updateSend()
    }

    func hideNudge() {
        guard !nudgeBar.isHidden else { return }
        nudgeField.resignFirstResponder()
        nudgeBar.isHidden = true
        scrollView.contentInset.bottom = 0
    }

    func updateSend() {
        let text = nudgeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        nudgeSend.isEnabled = !text.isEmpty && !isBusy
    }

    func sendNudge() {
        let text = nudgeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty, !isBusy else { return }
        isBusy = true
        updateSend()
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.hub.nudge(self.target.key, text: text)
            self.isBusy = false
            switch reply {
            case .sent:
                Theme.Haptics.success()
                self.nudgeField.text = nil
                self.hideNudge()
                self.say(String(localized: "Nudge queued. The agent reads it when its turn yields."))
            case .needsChat:
                DraftStore.record(
                    text, for: .chat(profileID: self.target.profileID, sessionID: self.target.sessionID))
                self.nudgeField.text = nil
                self.hideNudge()
                self.openChat()
            case .failed(let why):
                Theme.Haptics.error()
                MidgarLog.error("agent nudge failed", category: .session)
                self.say(why, failure: true)
            }
            self.render()
            self.updateSend()
        }
    }
}

extension AgentPeekViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendNudge()
        return false
    }
}
