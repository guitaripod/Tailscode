import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit

extension ChatViewController {
    /// The agent this chat is with, as the chooser needs it: an agent the server named, else the
    /// agent whose model the chat runs, else the server's own once anything has been said.
    var chatEngine: ChatEngine {
        if let agent = viewModel.session.agentID { return .agent(agent) }
        if let model = viewModel.displayedModel,
            availableModels.contains(where: {
                $0.agentName != nil && $0.providerID == model.providerID && $0.id == model.modelID
            })
        {
            return .agent(model.providerID)
        }
        return ChatEngine.of(agentID: nil, hasTurns: !viewModel.state.messages.isEmpty)
    }

    /// Holding Send offers the two things a held Send means: ask this later, or sharpen it first
    /// where the device can.
    func presentSendHold(text: String, from view: UIView) {
        guard enhancement.isAvailable else { return askLater(text: text, sessionID: nil) }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: ScheduleWords.askLaterMenu, style: .default) { [weak self] _ in
                self?.askLater(text: text, sessionID: nil)
            })
        sheet.addAction(
            UIAlertAction(title: Localized.text("Enhance prompt"), style: .default) { [weak self] _ in
                self?.enhanceFromHold(text)
            })
        sheet.addAction(UIAlertAction(title: Localized.text("Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = view.bounds
        present(sheet, animated: true)
    }

    /// The Ask later sheet for words typed here or sent before, on this chat's machine and model;
    /// from a message already sent, the schedule keeps running into this conversation.
    func askLater(text: String, sessionID: String?) {
        guard let profile = ConnectionController.shared.profiles.first(where: { $0.id == viewModel.contextID })
        else { return }
        Theme.Haptics.tap()
        AskLaterViewController.present(
            from: self,
            context: AskLaterViewController.Context(
                profile: profile, backend: viewModel.backend, text: text,
                selection: viewModel.displayedModel, effort: viewModel.displayedEffort,
                directory: viewModel.session.directory, sessionID: sessionID))
    }

    #if DEBUG
        /// The Ask later sheet over this chat with a question and a phrase already in it, for a
        /// screenshot without a hand.
        func openAskLaterForVerification() {
            guard let raw = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_ASK_LATER"] else { return }
            let phrase = raw == "1" ? ScheduleWords.example : raw
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self,
                    let profile = ConnectionController.shared.profiles.first(where: {
                        $0.id == self.viewModel.contextID
                    })
                else { return }
                AskLaterViewController.present(
                    from: self,
                    context: AskLaterViewController.Context(
                        profile: profile, backend: self.viewModel.backend,
                        text: "What's new in AI today? Three lines, links.",
                        selection: self.viewModel.displayedModel, effort: self.viewModel.displayedEffort,
                        directory: self.viewModel.session.directory, sessionID: nil),
                    phrase: phrase)
            }
        }
    #endif
}
