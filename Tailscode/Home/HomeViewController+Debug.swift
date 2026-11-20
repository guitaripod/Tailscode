import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension HomeViewController {
    #if DEBUG
        var tourScrollView: UIScrollView { collectionView }

        func tourFocusComposer() { composerBar.focus() }

        func tourType(_ text: String, perCharacter: Double) async {
            for index in text.indices {
                composerBar.tourSetText(String(text[text.startIndex...index]))
                try? await Task.sleep(for: .seconds(perCharacter))
            }
        }

        func tourSendComposer() { composerSend(composerBar.tourText) }

        func tourPushChats() { pushChats() }

        func tourPushSaved(seeding mode: String? = nil) {
            if let mode { seedSavedForVerification(mode) }
            pushSaved()
        }

        func tourOpenSettings() { onOpenSettings?() }

        func tourOpenAgents() { AgentsPresenter.present(from: self, animated: false) }

        func tourPop() { navigationController?.popViewController(animated: true) }

        /// Puts the board into its first-frame state for a take: no bookmarks carried
        /// over from an earlier run, and recent work that moved while you were away.
        func tourResetBoard(seenAge: TimeInterval) {
            for chat in SavedChatStore.all() {
                SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
            }
            SessionSeenStore.tourRewindBaseline(seenAge)
            savedChats = SavedChatStore.all()
            applySnapshot()
        }

        func tourAim(serverIndex: Int, directory: String?) {
            guard viewModel.servers.indices.contains(serverIndex) else { return }
            setComposeTarget(profile: viewModel.servers[serverIndex], directory: directory)
        }

        /// Presses the board's own controls on a clock, so its folds, its foot and its read press can
        /// be watched on a simulator without a hand: `3000:unseen=86400;5000:more;7000:fold=pinned`
        /// is milliseconds from launch and a verb each. `unseen` rewinds the read baseline so chats
        /// read as unread, `more` and `fewer` press RECENT's foot, `fold` presses a band's heading,
        /// `read` reads everything and `end` scrolls to the last row.
        func driveBoard(_ script: String) {
            for step in script.split(separator: ";") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let after = Double(parts[0]) else { continue }
                let verb = parts[1].split(separator: "=", maxSplits: 1).map(String.init)
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(after)))
                    guard let self else { return }
                    switch verb[0] {
                    case "unseen":
                        SessionSeenStore.tourRewindBaseline(Double(verb.last ?? "") ?? 86_400)
                        self.renderSnapshot()
                    case "more":
                        self.pressFoot(.more(hidden: 0))
                    case "fewer":
                        self.pressFoot(.fewer)
                    case "fold":
                        guard let band = SessionSection(rawValue: verb.last ?? "") else { return }
                        self.toggleFold(band)
                    case "read":
                        self.markEverythingRead()
                    case "end":
                        let last = self.collectionView.numberOfSections - 1
                        guard last >= 0 else { return }
                        let item = self.collectionView.numberOfItems(inSection: last) - 1
                        guard item >= 0 else { return }
                        self.collectionView.scrollToItem(
                            at: IndexPath(item: item, section: last), at: .bottom, animated: true)
                    default:
                        MidgarLog.info("home drive: no verb \(verb[0])", category: .ui)
                    }
                    let snapshot = self.dataSource.snapshot()
                    let counts = snapshot.sectionIdentifiers.map {
                        "\($0)=\(snapshot.numberOfItems(inSection: $0))"
                    }.joined(separator: " ")
                    MidgarLog.info(
                        "home drive: \(parts[1]) -> \(counts) news=\(self.hasNews)", category: .ui)
                }
            }
        }

        /// Puts the ask lane into a named state so each one can be reviewed without a hand:
        /// `attach` hangs a picture and a file in the strip, `failed` shows a diagnosis with its
        /// remedy above the box.
        func seedAskForVerification() {
            guard let mode = ProcessInfo.processInfo.environment["TAILSCODE_ASK_STATE"]
            else { return }
            switch mode {
            case "attach":
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                let png = renderer.image { context in
                    Theme.Color.accent.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                }.pngData() ?? Data()
                attachments = [
                    PendingAttachment(name: "shelf.png", mime: "image/png", data: png),
                    PendingAttachment(
                        name: "notes.txt", mime: "text/plain",
                        data: Data(repeating: 0x20, count: 2048)),
                ]
                composerBar.setDraft("What is on this shelf?", focus: false)
                refreshAttachments()
            case "failed":
                composerBar.setDraft("What is on this shelf?", focus: false)
                showFailure(
                    NewChatDiagnosis.failure(
                        server: NewChatServer(
                            profileID: "demo", name: composerAim?.profile.name ?? "studio",
                            backend: .claudeCode, address: "100.64.0.1:4098"),
                        directory: nil, error: "Connection refused", witness: .unknown))
            default: break
            }
        }
    #endif
}

#if DEBUG
    extension HomeViewController {
        /// Puts one of the screens no other launch hook reaches on screen, so the whole set can be
        /// photographed on every display and pose without a finger driving it.
        func presentDuoScreen(named name: String) {
            let profile = viewModel.servers.first
            switch name {
            case "newchat":
                guard let profile else { return }
                NewChatFlow.begin(from: self, profile: profile, viewModel: viewModel) { _ in }
            case "proupgrade":
                ProUpgradeViewController.present(from: self, placement: .settings)
            case "serveredit":
                guard let profile else { return }
                present(UINavigationController(rootViewController: ServerEditViewController(profile: profile)), animated: false)
            case "manualconnect":
                let device = TailscaleDevice(
                    name: "studio.tailnet-demo.ts.net", hostname: "studio", addresses: ["100.64.0.5"],
                    os: "macOS")
                present(
                    UINavigationController(rootViewController: ManualConnectViewController(device: device)),
                    animated: false)
            case "discovery":
                present(UINavigationController(rootViewController: DiscoveryViewController()), animated: false)
            case "librarypicker":
                let picker = ImageLibraryPickerViewController(library: DuoFixtures.library()) { _ in }
                present(UINavigationController(rootViewController: picker), animated: false)
            case "imageviewer":
                let viewer = ImageViewerViewController(
                    items: DuoFixtures.gallery(), startIndex: 1, backend: nil)
                present(viewer, animated: false)
            default:
                break
            }
        }
    }
#endif
