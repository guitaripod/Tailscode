import MidgarCore
import TailscodeCore
import UIKit

extension WatchViewController {
    private var tiles: [WallTile] { stage.wall.tiles }

    func approve(_ id: String) {
        guard let tile = tiles.first(where: { $0.id == id }), let ask = tile.ask else { return }
        guard ask.isApproval, style.approvals == .hold else {
            openChat(tile: id)
            return
        }
        guard !(actions[id]?.isBusy ?? false) else { return }
        actions[id] = .busy(.approve)
        applyWordsNow()
        Task { [weak self] in
            guard let self else { return }
            self.gateInFlight = true
            let outcome = await AgentsApprovalGate.confirm(
                reason: String(localized: "Approve a command for “\(tile.title)”"))
            self.gateInFlight = false
            switch outcome {
            case .allowed:
                let reply = await AgentsHub.shared.approve(id, allow: true)
                self.settle(reply, kind: .approve, id: id)
            case .cancelled:
                self.actions[id] = nil
                self.applyWordsNow()
            case .refused(let why):
                Theme.Haptics.error()
                self.fail(why, id: id)
            }
        }
    }

    func deny(_ id: String) {
        guard let tile = tiles.first(where: { $0.id == id }), tile.ask?.isApproval == true,
            !(actions[id]?.isBusy ?? false)
        else { return }
        actions[id] = .busy(.deny)
        applyWordsNow()
        Task { [weak self] in
            guard let self else { return }
            let reply = await AgentsHub.shared.approve(id, allow: false)
            self.settle(reply, kind: .deny, id: id)
        }
    }

    private func settle(_ reply: AgentTower.Reply, kind: WatchAction.Kind, id: String) {
        switch reply {
        case .sent:
            Theme.Haptics.success()
            flash(.done(kind), for: id, lasts: .seconds(8))
        case .needsChat:
            actions[id] = nil
            applyWordsNow()
            openChat(tile: id)
        case .failed(let why):
            Theme.Haptics.error()
            MidgarLog.error("agents wall answer failed", category: .session)
            fail(why, id: id)
        }
    }

    private func fail(_ why: String, id: String) {
        flash(.failed(why), for: id, lasts: .seconds(4))
    }

    func openChat(tile id: String) {
        guard let tile = tiles.first(where: { $0.id == id }) else { return }
        openChat(sessionID: tile.sessionID)
    }

    func openChat(key: String) {
        let session = feed.board.finished.first { $0.id == key }?.sessionID
            ?? feed.board.row(key)?.sessionID ?? key.split(separator: "/").last.map(String.init)
        if let session { openChat(sessionID: session) }
    }

    func openChat(sessionID: String) {
        guard let url = SceneRouting.sessionURL(sessionID) else { return }
        Theme.Haptics.tap()
        MidgarLog.info("agents wall opens chat", category: .session)
        if standalone {
            PendingRoute.deliver(url)
            activateApp()
        } else {
            close { PendingRoute.deliver(url) }
        }
    }

    private func activateApp() {
        let app = UIApplication.shared
        let main = app.openSessions.first { ($0.scene?.delegate as? SceneDelegate)?.hostsApp == true }
        guard let main else { return }
        app.requestSceneSessionActivation(main, userActivity: nil, options: nil, errorHandler: nil)
    }

    func close(then completion: (() -> Void)? = nil) {
        suspend()
        if standalone, let session = view.window?.windowScene?.session {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
            completion?()
            return
        }
        guard presentingViewController != nil else {
            completion?()
            return
        }
        dismiss(animated: true, completion: completion)
    }
}
