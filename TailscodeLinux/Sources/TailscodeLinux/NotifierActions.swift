import CodingAgentKit
import Foundation
import TailscodeCore

/// What a notice can do from outside the window: send the next message of the chat it is about,
/// and answer the question it asks. Both go through the conversation the hub already holds for the
/// chat when a pane or a watch has one, and through a fresh one when none does, so a reply typed
/// into a notice for a chat nobody has open still lands in that chat.
extension MainWindow {
    /// The words a notice's reply field or its Try again button hands over, sent as the chat's
    /// next message on the model and effort the chat is on. The queue holds while the server shows
    /// the turn, as it does for a pane's own send. A send that cannot go is raised again with the
    /// words in it, because words typed into a notification have no composer to be found in.
    func sendFromNotification(
        profileID: String, sessionID: String, words: String, identifier: String
    ) {
        let key = LiveKey(profileID: profileID, sessionID: sessionID)
        let entry = entries.first { $0.profileID == profileID && $0.session.id == sessionID }
        let title = entry?.session.title ?? "Tailscode"
        let choice = noticeChoice(for: key, entry: entry)
        let hub = live.hub
        let edges = live.edges
        edges.beganSend(key, after: hub.latest(key)?.state)
        Task {
            do {
                guard let conversation = await Self.noticeConversation(key, hub: hub) else {
                    throw CancellationError()
                }
                try await conversation.send(
                    words, model: choice.model, reasoningEffort: choice.effort)
                Gtk.onMain { Notifier.shared.withdraw([identifier]) }
            } catch {
                edges.endedSend(key)
                Gtk.onMain { Notifier.shared.reportUnsent(title: title, words: words) }
            }
        }
    }

    /// An answer picked on a notice's button or typed into its field. A server that takes answers
    /// as messages gets one on the ordinary send path, and the card in the chat is settled so it
    /// stops asking, exactly as the pane does it.
    func answerFromNotification(
        profileID: String, question: QuestionRequest, answers: [[String]], identifier: String
    ) {
        let key = LiveKey(profileID: profileID, sessionID: question.sessionID)
        let entry = entries.first { $0.profileID == profileID && $0.session.id == question.sessionID }
        let title = entry?.session.title ?? "Tailscode"
        let choice = noticeChoice(for: key, entry: entry)
        let hub = live.hub
        let edges = live.edges
        let spoken = answers.flatMap { $0 }.joined(separator: ", ")
        Task {
            do {
                guard let conversation = await Self.noticeConversation(key, hub: hub),
                    let profile = await ServerDirectory.shared.profiles()
                        .first(where: { $0.id == profileID }),
                    let backend = await ServerDirectory.shared.backend(for: profile)
                else { throw CancellationError() }
                if backend.capabilities.answersQuestionsByMessage {
                    edges.beganSend(key, after: hub.latest(key)?.state)
                    await conversation.markAnswered(question)
                    try await conversation.send(
                        question.answerMessage(answers), model: choice.model,
                        reasoningEffort: choice.effort)
                } else {
                    try await conversation.answer(question, answers: answers)
                }
                Gtk.onMain { Notifier.shared.withdraw([identifier]) }
            } catch {
                edges.endedSend(key)
                Gtk.onMain { Notifier.shared.reportUnsent(title: title, words: spoken) }
            }
        }
    }

    /// The model and effort a chat opens on, in the order its row and its composer read them, so
    /// a reply from a notice does not move a chat onto the server's default.
    private func noticeChoice(
        for key: LiveKey, entry: SessionEntry?
    ) -> (model: ModelSelection?, effort: String?) {
        let preference = "\(key.profileID)/\(key.sessionID)"
        return (
            ModelPreferenceStore.initialModel(
                sessionKey: preference, contextID: key.profileID,
                sessionModel: entry?.session.model,
                sessionModelProviderID: entry?.session.modelProviderID),
            EffortPreferenceStore.initialEffort(
                sessionKey: preference, contextID: key.profileID,
                sessionEffort: entry?.session.reasoningEffort)
        )
    }

    private static func noticeConversation(
        _ key: LiveKey, hub: ConversationHub
    ) async -> AgentConversation? {
        if let held = await hub.conversation(for: key) { return held }
        return await LiveRuntime.open(key)
    }
}
