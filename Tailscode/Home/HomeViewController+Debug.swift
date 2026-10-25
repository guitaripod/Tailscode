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
                ProUpgradeViewController.present(from: self)
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
                    items: DuoFixtures.gallery(), startIndex: 1, backend: nil, from: nil)
                present(viewer, animated: false)
            default:
                break
            }
        }
    }
#endif
