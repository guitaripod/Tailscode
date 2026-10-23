import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    var pendingSends: [PendingSend] { pending.sends }

    func resumePlan(for row: UUID) -> ResumePlan? { resume.plan(for: row) }

    /// The wait a client puts in the chat's own chrome: the soonest one, because that is the
    /// clock that decides when this conversation moves again.
    var soonestResume: ResumePlan? {
        resume.plans.values.filter { !$0.isStale() }.min { $0.resumesAt < $1.resumesAt }
    }

    private var resumeEnabled: Bool { AppPreferences.autoResume }

    private func resumeQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend.agentType, among: UsageWidgetStore.cachedQuotas())
    }

    /// A send a wall stopped is held rather than left as a failure nobody will come back to.
    /// Anything that is not a wall keeps its own sentence and never reaches this.
    func armResume(row: UUID, reason: String) {
        guard let send = pending.send(id: row) else { return }
        adopt(
            AutoResume.decide(
                row: row, profileID: contextID, sessionID: session.id, trigger: .refused,
                failure: reason, quotas: resumeQuotas(), model: displayedModel?.modelID,
                selection: displayedModel, enabled: resumeEnabled, attempt: resumeAttempts),
            text: send.text, attachments: send.attachments, model: send.model,
            effort: send.effort)
    }

    /// A turn that reached the server, ran into the wall and produced nothing is the commonest
    /// shape of this on a Claude machine: the prompt is already in the transcript, so the words
    /// come from there rather than from a send this device happens to remember.
    func armResumeForWalledTurn(_ state: ConversationState) {
        guard let failure = state.lastFailure, state.status != .running else {
            if state.lastFailure == nil { resumeAttempts = 0 }
            return
        }
        guard !resume.plans.values.contains(where: { $0.trigger == .answerless }) else { return }
        guard let asked = state.messages.last(where: { $0.role == .user }) else { return }
        let words = asked.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let answer = state.messages.last {
            $0.role == .assistant && $0.createdAt >= asked.createdAt
        }
        guard answer == nil || AutoResume.mayAskAgain(answer) else {
            if QuotaSurface.isQuotaFailure(failure.message) {
                onError?(ResumeReading.obstacle(.turnHadStarted))
            }
            return
        }
        adopt(
            AutoResume.decide(
                row: UUID(), profileID: contextID, sessionID: session.id, trigger: .answerless,
                failure: failure.message, quotas: resumeQuotas(),
                model: displayedModel?.modelID, selection: displayedModel,
                enabled: resumeEnabled, attempt: resumeAttempts),
            text: words, attachments: [], model: selectedModel, effort: currentEffort)
    }

    /// Takes a verdict and does the one thing it asks for: hold the words and start the clock, or
    /// say out loud why nothing is being waited for.
    func adopt(
        _ verdict: ResumeVerdict, text: String, attachments: [PromptAttachment],
        model: ModelSelection?, effort: String?
    ) {
        switch verdict {
        case .notAWall:
            return
        case .cannot(let obstacle):
            AppLogger.chat.info("resume declined: \(String(describing: obstacle))")
        case .resume(let plan):
            AppLogger.chat.info(
                "resume armed session=\(self.session.id) in=\(Int(plan.remaining()))s")
            resume.hold(plan)
            ResumeStore.hold(
                ResumeRecord(
                    plan: plan, text: text, attachments: attachments, model: model,
                    effort: effort))
            onResumeChange?(plan)
            startResumeClock()
            onPending?()
        }
    }

    /// One clock for the whole conversation. A countdown written in minutes needs nothing finer,
    /// and the grace this policy adds to every reset is four times the slop.
    private func startResumeClock() {
        guard resumeClock == nil, !resume.isEmpty else { return }
        resumeClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await self?.serviceResume()
            }
        }
    }

    func stopResumeClockIfIdle() {
        guard resume.isEmpty else { return }
        resumeClock?.cancel()
        resumeClock = nil
    }

    /// The moment a plan is due: look at the gauges rather than assume, then send, wait again, or
    /// stop and say why. Also called on foregrounding, because a phone that was asleep through
    /// the window opening is the ordinary case rather than the exception.
    func serviceResume() {
        guard !resume.isEmpty else {
            stopResumeClockIfIdle()
            return
        }
        for plan in resume.stale() {
            resume.drop(plan.id)
            ResumeStore.release(plan.id)
            onError?(ResumeReading.missed(plan))
            onResumeChange?(nil)
        }
        for plan in resume.due() {
            let resending = pending.send(id: plan.id)?.model ?? displayedModel
            switch AutoResume.recheck(
                plan, quotas: resumeQuotas(), model: resending?.modelID,
                selection: resending, enabled: resumeEnabled)
            {
            case .send:
                fireResume(plan)
            case .wait(let next):
                resume.hold(next)
                ResumeStore.replan(next)
                onResumeChange?(next)
            case .cancel(let obstacle):
                resume.drop(plan.id)
                ResumeStore.release(plan.id)
                onError?(ResumeReading.obstacle(obstacle))
                onResumeChange?(nil)
            }
        }
        stopResumeClockIfIdle()
        onPending?()
    }

    /// Sends what a plan was holding, through the composer's own path so a resumed message is a
    /// message like any other rather than a second road into the backend.
    private func fireResume(_ plan: ResumePlan) {
        resumeAttempts = plan.attempt + 1
        let record = ResumeStore.release(plan.id)
        resume.drop(plan.id)
        onResumeChange?(nil)
        let held = pending.send(id: plan.id)
        let text = held?.text ?? record?.text ?? ""
        guard !text.isEmpty else { return }
        AppLogger.chat.info("resume firing session=\(self.session.id)")
        let attachments = held?.attachments ?? record?.attachments ?? []
        let model = held?.model ?? record?.model ?? selectedModel
        let effort = held?.effort ?? record?.effort ?? currentEffort
        if held != nil, !isBusy {
            deliver(
                text, model: model, effort: effort, attachments: attachments, reusing: plan.id)
        } else {
            pending.remove(id: plan.id)
            send(text, model: model, effort: effort, attachments: attachments)
        }
    }

    func actOnResume(_ id: UUID, _ act: ResumeReading.Act) -> PendingSend? {
        guard let plan = resume.plan(for: id) else { return nil }
        switch act {
        case .sendNow:
            fireResume(plan)
            return nil
        case .edit:
            resume.drop(id)
            ResumeStore.release(id)
            onResumeChange?(nil)
            stopResumeClockIfIdle()
            return takeBackPending(id: id)
        case .stopWaiting:
            resume.drop(id)
            ResumeStore.release(id)
            onResumeChange?(nil)
            stopResumeClockIfIdle()
            onPending?()
            return nil
        }
    }

    /// Picks back up what this device was holding for this conversation when it was last running.
    /// A plan whose window opened while nothing was awake is reported rather than fired.
    func restoreHeldMessages() {
        let records = ResumeStore.records(profileID: contextID, sessionID: session.id)
        guard !records.isEmpty else { return }
        let userMessages = state.messages.count { $0.role == .user }
        for record in records {
            if record.plan.isStale() {
                ResumeStore.release(record.id)
                onError?(ResumeReading.missed(record.plan))
                continue
            }
            let restored = pending.begin(
                text: record.text, attachments: record.attachments, model: record.model,
                effort: record.effort, userMessages: userMessages, now: record.plan.plannedAt,
                id: record.id)
            pending.mark(
                id: restored.id,
                .failed(
                    reason: String(
                        format: String(localized: "%@ %@ is used up"), record.plan.provider,
                        record.plan.window)))
            resume.hold(record.plan)
        }
        startResumeClock()
        onPending?()
    }
}
