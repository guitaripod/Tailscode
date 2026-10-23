import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The windows that stand in front of what this chat would send with — the same reading the
    /// band and the model picker use.
    private func resumeQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend?.agentType, among: quotasForStatus?() ?? [])
    }

    /// A send a wall stopped is held rather than left as a failure nobody will come back to.
    func armResume(row: UUID, reason: String) {
        guard let entry, let send = pending.send(id: row) else { return }
        adopt(
            AutoResume.decide(
                row: row, profileID: entry.profileID, sessionID: entry.session.id,
                trigger: .refused, failure: reason, quotas: resumeQuotas(),
                model: composer.activeModelID, selection: composer.activeSelection,
                enabled: resumeEnabled, attempt: resumeAttempts),
            text: send.text, attachments: send.attachments, model: send.model,
            effort: send.effort)
    }

    /// A turn that reached the server, ran into the wall and produced nothing is the commonest
    /// shape of this on a Claude machine: the prompt is already in the transcript, so the words
    /// come from there rather than from a send this device happens to remember.
    func armResumeForWalledTurn(_ state: ConversationState) {
        guard let entry, let failure = state.lastFailure, state.status != .running else {
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
                onToast?(ResumeReading.obstacle(.turnHadStarted))
            }
            return
        }
        adopt(
            AutoResume.decide(
                row: UUID(), profileID: entry.profileID, sessionID: entry.session.id,
                trigger: .answerless, failure: failure.message, quotas: resumeQuotas(),
                model: composer.activeModelID, selection: composer.activeSelection,
                enabled: resumeEnabled, attempt: resumeAttempts),
            text: words, attachments: [], model: composer.pickedModel,
            effort: composer.activeEffort)
    }

    /// Takes a verdict and does the one thing it asks for: hold the words and start the clock, or
    /// say out loud why nothing is being waited for.
    private func adopt(
        _ verdict: ResumeVerdict, text: String, attachments: [PromptAttachment],
        model: ModelSelection?, effort: String?
    ) {
        switch verdict {
        case .notAWall:
            return
        case .cannot(let obstacle):
            onToast?(ResumeReading.obstacle(obstacle))
        case .resume(let plan):
            resume.hold(plan)
            ResumeStore.hold(
                ResumeRecord(
                    plan: plan, text: text, attachments: attachments, model: model,
                    effort: effort))
            startResumeClock()
            redrawPending()
        }
    }

    /// One clock for the whole transcript. A countdown written in minutes needs nothing finer,
    /// and the grace this policy adds to every reset is three times the slop.
    func startResumeClock() {
        guard resumeClock == nil, !resume.isEmpty else { return }
        resumeClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                self?.serviceResume()
            }
        }
    }

    private func stopResumeClockIfIdle() {
        guard resume.isEmpty else { return }
        resumeClock?.cancel()
        resumeClock = nil
    }

    /// The moment a plan is due: look at the gauges rather than assume, then send, wait again, or
    /// stop and say why.
    func serviceResume() {
        guard !resume.isEmpty else {
            stopResumeClockIfIdle()
            return
        }
        for plan in resume.stale() {
            resume.drop(plan.id)
            ResumeStore.release(plan.id)
            onToast?(ResumeReading.missed(plan))
        }
        for plan in resume.due() {
            let resending = pending.send(id: plan.id)?.model ?? composer.activeSelection
            switch AutoResume.recheck(
                plan, quotas: resumeQuotas(), model: resending?.modelID,
                selection: resending, enabled: resumeEnabled)
            {
            case .send:
                onToast?(ResumeReading.firing(plan))
                fireResume(plan)
            case .wait(let next):
                resume.hold(next)
                ResumeStore.replan(next)
            case .cancel(let obstacle):
                resume.drop(plan.id)
                ResumeStore.release(plan.id)
                onToast?(ResumeReading.obstacle(obstacle))
            }
        }
        stopResumeClockIfIdle()
        redrawPending()
    }

    /// Sends what a plan was holding, through the composer's own path so a resumed message is a
    /// message like any other rather than a second road into the backend.
    private func fireResume(_ plan: ResumePlan) {
        resumeAttempts = plan.attempt + 1
        let record = ResumeStore.release(plan.id)
        resume.drop(plan.id)
        let held = pending.send(id: plan.id)
        let text = held?.text ?? record?.text ?? ""
        guard !text.isEmpty else { return }
        let attachments = held?.attachments ?? record?.attachments ?? []
        let model = held?.model ?? record?.model ?? composer.pickedModel
        let effort = held?.effort ?? record?.effort ?? composer.activeEffort
        if held != nil {
            sendPrompt(
                text, model: model, effort: effort, attachments: attachments, reusing: plan.id)
        } else {
            sendPrompt(text, model: model, effort: effort, attachments: attachments)
        }
    }

    func actOnResume(_ id: UUID, _ act: ResumeReading.Act) {
        guard let plan = resume.plan(for: id) else { return }
        switch act {
        case .sendNow:
            fireResume(plan)
        case .edit:
            resume.drop(id)
            ResumeStore.release(id)
            actOnPending(id, .edit)
        case .stopWaiting:
            resume.drop(id)
            ResumeStore.release(id)
            onToast?(ResumeReading.stopped(plan))
            redrawPending()
        }
        stopResumeClockIfIdle()
    }

    /// Picks back up what this device was holding for this conversation when it was last running.
    /// A plan whose window opened while nothing was awake is reported rather than fired.
    func restoreHeldMessages() {
        guard let entry else { return }
        let records = ResumeStore.records(
            profileID: entry.profileID, sessionID: entry.session.id)
        guard !records.isEmpty else { return }
        let userMessages = lastState?.messages.count { $0.role == .user } ?? 0
        for record in records {
            if record.plan.isStale() {
                ResumeStore.release(record.id)
                onToast?(ResumeReading.missed(record.plan))
                continue
            }
            let restored = pending.begin(
                text: record.text, attachments: record.attachments, model: record.model,
                effort: record.effort, userMessages: userMessages, now: record.plan.plannedAt,
                id: record.id)
            pending.mark(
                id: restored.id,
                .failed(
                    reason: Localized.text(
                        "%@ %@ is used up", record.plan.provider, record.plan.window)))
            resume.hold(record.plan)
        }
        startResumeClock()
        redrawPending()
    }
}
