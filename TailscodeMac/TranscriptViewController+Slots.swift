import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The strip that says whose conversation this pane is — only worth its line once a second
    /// pane exists, so a lone pane stays exactly the window it always was.
    func setIdentityVisible(_ visible: Bool) {
        let changed = identityGlass?.isHidden == visible
        identityGlass?.isHidden = !visible
        identityStrip?.isHidden = !visible
        refreshIdentity()
        if changed { view.needsLayout = true }
    }

    /// What the tiling adds to the pane's name: a pin when the person asked to keep it live, and
    /// which other pane shows the same chat, so two views of one conversation are never mistaken
    /// for two conversations.
    func setIdentityExtras(pinned: Bool, alsoOpenIn other: Int?) {
        identityPin.isHidden = !pinned
        identityAlso.isHidden = other == nil
        if let other {
            identityAlso.stringValue = "· " + Localized.text("also open in pane %@", "\(other)")
        }
    }

    /// A pane holds one thing at a time. A chat opened into a slot binds, streams, retitles the
    /// window and starts notifying behind a player that still covers the pane edge to edge — live
    /// and invisible, with no way back short of closing the pane — so the slot goes first.
    func clearSlot() {
        guard isWatching || page != nil || draw != nil || preview != nil else { return }
        preview?.shutdown()
        preview?.removeFromSuperview()
        preview = nil
        draw?.shutdown()
        draw?.removeFromSuperview()
        draw = nil
        #if !TAILSCODE_MAS
            video?.shutdown()
            video?.removeFromSuperview()
            video = nil
        #endif
        page?.shutdown()
        page?.removeFromSuperview()
        page = nil
        setChatFurnitureVisible(true)
        refreshIdentity()
        onVideoChanged?()
    }

    #if !TAILSCODE_MAS
        /// Turns this pane into a video slot, or points the one it already is at something else.
        /// The chat furniture is hidden rather than destroyed, so a slot is a state of a pane and
        /// not a second kind of object the tiling would have to learn.
        func showVideo(_ target: VideoTarget?) {
            chooser = nil
            chooserView.isHidden = true
            if video == nil {
                let slot = VideoSlotView(target: target)
                slot.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
                NSLayoutConstraint.activate([
                    slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    slot.topAnchor.constraint(equalTo: view.topAnchor),
                    slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                ])
                video = slot
                slot.onChange = { [weak self] in
                    self?.refreshIdentity()
                    self?.onVideoChanged?()
                }
                setChatFurnitureVisible(false)
            } else if let target {
                video?.point(at: target)
            }
            if target == nil { video?.focusPrompt() }
            refreshIdentity()
        }
    #endif

    /// Turns this pane into a browser slot, or points the one it already is at another address.
    func showWeb(_ target: WebTarget?) {
        chooser = nil
        chooserView.isHidden = true
        if page == nil {
            let slot = WebSlotView(target: target)
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
            NSLayoutConstraint.activate([
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                slot.topAnchor.constraint(equalTo: view.topAnchor),
                slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            page = slot
            slot.onChange = { [weak self] in
                self?.refreshIdentity()
                self?.onVideoChanged?()
            }
            setChatFurnitureVisible(false)
        } else if let target {
            page?.point(at: target)
        }
        if target == nil { page?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into a draw slot, or points the one it already is at another machine. The
    /// slot is the Studio's Image lane at pane size — the same stage, dock and shelf over a studio
    /// of its own — so a pane is never a second implementation of making a picture, and it is the
    /// same in both distributions: the machine is reached over the network and nothing else is asked.
    func showDraw(_ endpoint: ImageGenEndpoint?) {
        chooser = nil
        chooserView.isHidden = true
        if draw == nil {
            let slot = DrawSlotView(endpoint: endpoint)
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
            NSLayoutConstraint.activate([
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                slot.topAnchor.constraint(equalTo: view.topAnchor),
                slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            draw = slot
            slot.onChange = { [weak self] in
                self?.refreshIdentity()
                self?.onVideoChanged?()
            }
            setChatFurnitureVisible(false)
        } else if let endpoint {
            draw?.point(at: endpoint)
        }
        if endpoint == nil { draw?.focusPrompt() }
        refreshIdentity()
        onVideoChanged?()
    }

    /// Turns this pane into a preview slot, or points the one it already is at another app. A pane
    /// built from a snapshot starts its runner at once; one asked for with no target asks in its own
    /// body, and `fixedHost` names the Mac the chooser row already chose.
    func showPreview(
        _ target: PreviewTarget?, fixedHost: String? = nil, runs: Bool = true,
        secrets: (any SecretStore)? = nil
    ) {
        chooser = nil
        chooserView.isHidden = true
        if preview == nil {
            let slot = PreviewSlotView(
                target: target, fixedHost: fixedHost, runs: runs, secrets: secrets)
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
            NSLayoutConstraint.activate([
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                slot.topAnchor.constraint(equalTo: view.topAnchor),
                slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            preview = slot
            slot.onChange = { [weak self] in
                self?.refreshIdentity()
                self?.onVideoChanged?()
            }
            slot.onAskAgent = { [weak self] words in self?.onPreviewAskAgent?(words) }
            setChatFurnitureVisible(false)
            if isParked { slot.park() }
            view.needsLayout = true
        } else if let target {
            preview?.point(at: target)
        } else {
            preview?.ask()
        }
        if target == nil { preview?.focusPrompt() }
        refreshIdentity()
        onVideoChanged?()
    }

    /// The pane's name and face as the overflow strip wears them, for a preview that has no room.
    var previewIdentity: (title: String, activity: ActivityKind?)? {
        preview.map { ("\($0.slot.title) · \($0.slot.subtitle)", $0.slot.light.activity) }
    }

    /// A preview pane claims only plain letters, and only while the person is not typing into one
    /// of its fields: the picture takes no keys, so everything else belongs to the window.
    func handlePreviewChord(_ chord: KeyChord) -> Bool {
        guard let preview, !preview.isAsking, let command = PreviewCommand.command(for: chord) else {
            return false
        }
        preview.handle(command)
        return true
    }

    var webTarget: WebTarget? {
        page.flatMap { slot in slot.currentAddress.map(WebTarget.page) ?? slot.target }
    }

    /// A browsing pane claims only the chords a browser owns; every other key belongs to the page,
    /// which is typing into a form as often as not.
    func handleWebChord(_ chord: KeyChord) -> Bool {
        guard let page, let command = WebCommand.command(for: chord) else { return false }
        if page.isAsking, command == .address { return false }
        page.handle(command)
        return true
    }

    /// Everything the pane draws for a conversation, out of the way while it holds a stream —
    /// walked rather than named so a new piece of chat chrome cannot forget to hide itself, and
    /// remembered rather than re-derived on the way back, because what was hidden is not what is
    /// wanted: unhiding the whole list shows an empty completion popover and a find bar nobody
    /// opened.
    private func isVideoSlot(_ subview: NSView) -> Bool {
        #if TAILSCODE_MAS
            return false
        #else
            return subview === video
        #endif
    }

    private func setChatFurnitureVisible(_ visible: Bool) {
        guard !visible else {
            furnitureHidden.forEach { $0.isHidden = false }
            furnitureHidden = []
            return
        }
        guard furnitureHidden.isEmpty else { return }
        calls.leave(because: "something else took the pane")
        hoverBar.dismiss()
        railController.dismiss()
        furnitureHidden = view.subviews.filter { subview in
            subview !== identityGlass && subview !== page && subview !== draw
                && subview !== preview && !subview.isHidden && !isVideoSlot(subview)
        }
        furnitureHidden.forEach { $0.isHidden = true }
    }

    func refreshIdentity() {
        identityBadge.activity = preview?.slot.light.activity
        if identityBadge.activity == nil { identityBadge.isHidden = true }
        if let preview {
            identityLabel.stringValue = "\(preview.slot.title) · \(preview.slot.subtitle)"
            return
        }
        if let draw {
            identityLabel.stringValue = draw.title
            return
        }
        if let page {
            identityLabel.stringValue = "\(page.slot.title) · \(page.slot.subtitle)"
            return
        }
        #if !TAILSCODE_MAS
            if let video {
                identityLabel.stringValue = "\(video.slot.title) · \(video.slot.subtitle)"
                return
            }
        #endif
        guard let entry else {
            identityLabel.stringValue = Localized.text("No conversation")
            return
        }
        let title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        identityLabel.stringValue = title
    }
}
