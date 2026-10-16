import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore
import UIKit
import UserNotifications

/// What a notice can do from the Lock Screen: send the next message of the chat it is about, and
/// answer the question it asks.
///
/// The system wakes the app for a moment to deliver a button press, so each of these holds a
/// background task for the length of one request and gives up cleanly when it ends. A push names
/// its session and nothing else, so the server that holds the session is found the way the Missed
/// list finds it, from the last listing this device saw, and by asking each server when that has
/// nothing to say.
@MainActor
enum NoticeReplies {
    /// Words typed into a notice, or the prompt a failed turn began with, sent as the chat's next
    /// message on the model and effort that chat is on.
    static func send(
        _ words: String, sessionID: String, profileID: String?, identifier: String, title: String
    ) async {
        await hold("send") {
            guard let (profile, backend) = await locate(sessionID: sessionID, profileID: profileID)
            else { return false }
            let choice = await ChatModelResolver.choice(
                profileID: profile.id, backend: backend,
                sessionKey: "\(profile.id)/\(sessionID)")
            do {
                try await backend.send(
                    SendPrompt(
                        text: words, model: choice.model, reasoningEffort: choice.effort),
                    to: sessionID)
                return true
            } catch {
                AppLogger.session.error("notice reply failed: \(error)")
                return false
            }
        } done: { sent in
            finish(sent: sent, identifier: identifier, title: title, words: words)
        }
    }

    /// An option picked on a button or an answer typed into the field. A notice raised here
    /// carries the request whole; one a bridge pushed carries only the question's words, which is
    /// enough, because a server that pushes a question is one that takes its answer as a message.
    static func answer(
        _ answers: [[String]], question: QuestionRequest?, asked: String?, sessionID: String,
        profileID: String?, identifier: String, title: String
    ) async {
        let spoken = answers.flatMap { $0 }.joined(separator: ", ")
        await hold("answer") {
            guard let (profile, backend) = await locate(sessionID: sessionID, profileID: profileID)
            else { return false }
            do {
                if let question, !backend.capabilities.answersQuestionsByMessage {
                    try await backend.answerQuestion(question, answers: answers)
                    return true
                }
                let choice = await ChatModelResolver.choice(
                    profileID: profile.id, backend: backend,
                    sessionKey: "\(profile.id)/\(sessionID)")
                guard question != nil || !(asked ?? "").isEmpty else {
                    try await backend.send(
                        SendPrompt(
                            text: spoken, model: choice.model, reasoningEffort: choice.effort),
                        to: sessionID)
                    return true
                }
                let request =
                    question
                    ?? QuestionRequest(
                        id: identifier, sessionID: sessionID,
                        questions: [
                            QuestionRequest.Item(
                                question: asked ?? "", header: "", options: [])
                        ])
                try await backend.send(
                    SendPrompt(
                        text: request.answerMessage(answers), model: choice.model,
                        reasoningEffort: choice.effort),
                    to: sessionID)
                return true
            } catch {
                AppLogger.session.error("notice answer failed: \(error)")
                return false
            }
        } done: { sent in
            finish(sent: sent, identifier: identifier, title: title, words: spoken)
        }
    }

    private static func finish(sent: Bool, identifier: String, title: String, words: String) {
        if sent {
            NotificationManager.withdraw(identifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = String(localized: "Couldn't send")
        content.body = words
        content.sound = .default
        content.interruptionLevel = .active
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "unsent:\(identifier)", content: content, trigger: nil))
    }

    private static func hold(
        _ name: String, _ work: @MainActor () async -> Bool,
        done: @MainActor (Bool) -> Void
    ) async {
        let task = UIApplication.shared.beginBackgroundTask(withName: "NoticeReplies.\(name)")
        let sent = await work()
        done(sent)
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private static func locate(sessionID: String, profileID: String?) async -> (
        ConnectionProfile, any CodingAgentBackend
    )? {
        let controller = ConnectionController.shared
        let known = profileID ?? NoticeOwners.profileID(for: sessionID)
        if let known, let profile = controller.profiles.first(where: { $0.id == known }),
            let backend = controller.makeBackend(for: profile)
        {
            return (profile, backend)
        }
        for profile in controller.profiles where !profile.id.hasPrefix(DemoWorld.profilePrefix) {
            guard let backend = controller.makeBackend(for: profile),
                let sessions = try? await backend.listSessions(),
                sessions.contains(where: { $0.id == sessionID })
            else { continue }
            NoticeOwners.remember([sessionID: profile.id])
            return (profile, backend)
        }
        AppLogger.session.error("notice reply: no server holds session \(sessionID)")
        return nil
    }
}

/// Which server holds which session, as far as this device has seen, kept so a push that names a
/// session and nothing else can be answered without asking every server.
enum NoticeOwners {
    private static let key = "tailscode.notice.owners"
    private static let limit = 400

    static func profileID(for sessionID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[sessionID]
    }

    static func remember(_ owners: [String: String]) {
        guard !owners.isEmpty else { return }
        var known = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        for (session, profile) in owners { known[session] = profile }
        if known.count > limit {
            for stale in known.keys.sorted().prefix(known.count - limit) { known[stale] = nil }
        }
        UserDefaults.standard.set(known, forKey: key)
    }
}
