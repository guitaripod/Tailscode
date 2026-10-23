import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TileHost {
    /// A chip in the strip pressed: out of the zoom onto that pane, or, when the window had no room
    /// for it, swapped in for the placed pane focused longest ago.
    func reveal(_ id: PaneID) {
        guard layout.contains(id), let placement = currentPlacement() else { return }
        if let zoomed = layout.zoomedPane {
            layout.toggleZoom(zoomed)
            layout.focus(id)
        } else if !placement.isPlaced(id),
            let stale = layout.recentlyFocused.reversed().first(where: { placement.isPlaced($0) })
        {
            layout.swap(id, stale)
            layout.focus(id)
        } else {
            layout.focus(id)
        }
        relayout()
        host?.focusedPaneChanged()
        persist()
    }

    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard host != nil, snapshot.layout.isValid else { return [:] }
        for id in Array(panes.keys) { retire(id) }
        layout = snapshot.layout
        pinned = Set(layout.paneIDs.filter { snapshot.isPinned($0) })
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = makePane(id)
            adopt(pane, as: id)
            switch snapshot.content(for: id) {
            case .draw(let address):
                pane.showDraw(ImageGenEndpoint(address: address))
            case .preview:
                if let target = snapshot.preview(for: id) { pane.showPreview(target) }
            case .web:
                if let target = snapshot.page(for: id) { pane.showWeb(target) }
            case .video:
                if let target = snapshot.video(for: id) { pane.showVideo(target) }
            case .chat(let session):
                bindings[id] = session
                pane.showPlaceholder(Localized.text("Connecting…"))
            case .empty:
                pane.showPlaceholder(Localized.text("Pick a chat, or n for a new one."))
            }
        }
        relayout()
        return bindings
    }

    func snapshot() -> SplitSnapshot {
        var contents: [String: PaneContent] = [:]
        for (id, pane) in panes {
            if let target = pane.previewTarget {
                contents[id.raw] = .preview(target.address)
            } else if let endpoint = pane.drawEndpoint {
                contents[id.raw] = .draw(endpoint.address)
            } else if let target = pane.webTarget {
                contents[id.raw] = .web(target.address)
            } else if let target = pane.videoTarget {
                contents[id.raw] = .video(target.address)
            } else if let entry = pane.entry {
                contents[id.raw] = .chat(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))
            } else if let session = host?.heldSession(for: id) {
                contents[id.raw] = .chat(session)
            }
        }
        return SplitSnapshot(
            layout: layout, contents: contents,
            pinned: layout.paneIDs.filter { pinned.contains($0) }.map(\.raw))
    }

    /// A lone pane needs no layout written — except when it is a slot, which is the one thing a
    /// single pane can hold that the chat list cannot restore on its own.
    func persist() {
        persistRequests += 1
        let snapshot = snapshot()
        guard let encoded = snapshot.encoded else { return }
        let slots = snapshot.contents.values.contains { $0.kind != .chat && $0 != .empty }
        SettingsFile.set(paneCount > 1 || slots ? encoded : nil, forKey: SplitSnapshot.defaultsKey)
        if currentKinds() != reconciledKinds {
            reconcile()
            applyFocusStyling()
        }
    }

    /// The tree changed: place it now, in this pass, and settle every density.
    func relayout() {
        refreshPlacement()
        canvas.invalidate()
        reconcile()
        applyFocusStyling()
    }

    func refreshPlacement() {
        let size = canvas.size
        guard size.width > 0, size.height > 0 else { return }
        let fresh = solvePlacement(size)
        placement = fresh
        syncDividers(fresh)
    }

    /// Density changes found during an allocation are applied after it, so the allocation never
    /// shows or hides a face mid-flight.
    func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            let hadDividers = self.dividersStale
            self.refreshPlacement()
            if hadDividers { self.canvas.invalidate() }
            self.reconcile()
            self.applyFocusStyling()
        }
    }

    func densityGeometryChanged(_ placement: PanePlacement) -> Bool {
        for (id, rect) in placement.frames {
            guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else {
                continue
            }
            let was = sizeAllowsFull[id] ?? true
            if PaneSizing.allowsFull(width: rect.width, height: rect.height, wasFull: was) != was {
                return true
            }
        }
        return false
    }

    func currentKinds() -> [PaneID: PaneKind] {
        var kinds: [PaneID: PaneKind] = [:]
        for (id, pane) in panes { kinds[id] = pane.paneKind(held: held[id] != nil) }
        return kinds
    }

    /// The face every pane should wear now: hidden panes park with nothing; a paused or held chat
    /// wears the paused face; a chat too small to read whole is a glance; the focused chat is
    /// whole; the rest take the governor's word, capped at its full budget with pinned panes and
    /// the most recently touched first, so focusing a glance makes it whole at once and the
    /// longest-untouched whole peer is the one that steps down.
    func reconcile() {
        guard let placement else { return }
        reconciledKinds = currentKinds()
        let focusedID = layout.focusedPane
        let now = Self.now
        var faces: [PaneID: TileShell.Face] = [:]
        var hidden: Set<PaneID> = []
        var contenders: [PaneID] = []
        var focusedFull = false
        let honourPins = !(decision?.level.overridesPreference ?? false)
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            guard let rect = placement.frames[id] else {
                hidden.insert(id)
                continue
            }
            let kind = pane.paneKind(held: held[id] != nil)
            if held[id] != nil || (userParked.contains(id) && kind == .chat) {
                faces[id] = .paused
                continue
            }
            guard kind == .chat else {
                faces[id] = .full
                continue
            }
            let fits = PaneSizing.allowsFull(
                width: rect.width, height: rect.height, wasFull: sizeAllowsFull[id] ?? true)
            sizeAllowsFull[id] = fits
            guard fits else {
                faces[id] = .glance
                continue
            }
            if id == focusedID {
                let holding = (promotionHold[id] ?? 0) > now
                faces[id] = holding ? .glance : .full
                focusedFull = !holding
                continue
            }
            if decision.map({ $0.densities[id] == .glance }) ?? false,
                !(honourPins && pinned.contains(id))
            {
                faces[id] = .glance
            } else {
                contenders.append(id)
            }
        }
        let budget = decision?.fullBudget ?? Int.max
        var remaining = budget == Int.max ? Int.max : max(0, budget - (focusedFull ? 1 : 0))
        let recent = layout.recentlyFocused
        let ranked = contenders.sorted { lhs, rhs in
            if honourPins, pinned.contains(lhs) != pinned.contains(rhs) {
                return pinned.contains(lhs)
            }
            return (recent.firstIndex(of: lhs) ?? .max) < (recent.firstIndex(of: rhs) ?? .max)
        }
        for id in ranked {
            if remaining > 0 {
                faces[id] = .full
                if remaining != .max { remaining -= 1 }
            } else {
                faces[id] = .glance
            }
        }
        for id in layout.paneIDs {
            if hidden.contains(id) {
                park(id)
            } else if let face = faces[id] {
                wear(face, id: id)
            }
        }
        describeDividers()
        refreshStrip()
        speakPanes()
        onDensityChanged?()
    }

    /// Each divider introduces itself again whenever where it stands, how far it may travel or
    /// which panes it divides has changed — a conversation opening in a pane changes what the
    /// pane needs, and so how far its neighbours' dividers may go.
    func describeDividers() {
        guard let placement else { return }
        for divider in placement.dividers {
            dividers[divider.id]?.describe(divider, label: dividerLabel(divider.id))
        }
    }

    /// Out of sight: no stream, no clock, no glance; the rows stay for an instant unzoom.
    func park(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        shells[id]?.glance?.stopClock()
        panes[id]?.park()
        panes[id]?.setRowWindow(nil)
        scheduleRelease(id)
    }

    func wear(_ face: TileShell.Face, id: PaneID) {
        guard let pane = panes[id], let shell = shells[id] else { return }
        switch face {
        case .full:
            feeds.removeValue(forKey: id)?.cancel()
            releaseTokens[id] = nil
            shell.glance?.stopClock()
            shell.show(.full)
            pane.setRowWindow(id == layout.focusedPane ? nil : decision?.rowWindows[id])
            pane.unpark()
        case .glance:
            pane.park()
            pane.setRowWindow(nil)
            let fresh = !shell.hasGlance
            let tile = shell.ensureGlance()
            shell.show(.glance)
            if fresh { wireGlance(tile, id: id) }
            startFeed(id)
            renderGlance(id)
            scheduleRelease(id)
        case .paused:
            feeds.removeValue(forKey: id)?.cancel()
            shell.glance?.stopClock()
            pane.park()
            shell.show(.paused)
            renderPaused(id)
            scheduleRelease(id)
        }
    }

    func wireGlance(_ tile: GlanceTile, id: PaneID) {
        let titles: @Sendable (String) -> String = { SplitMenu.definition($0)?.title ?? $0 }
        tile.wire(
            GlanceTile.Actions(
                openFull: { [weak self] in Gtk.onMain { [weak self] in self?.openFull(id) } },
                keepLive: { [weak self] in Gtk.onMain { [weak self] in self?.togglePin(id) } },
                pause: { [weak self] in Gtk.onMain { [weak self] in self?.togglePark(id) } },
                close: { [weak self] in Gtk.onMain { [weak self] in self?.close(id) } },
                zoom: { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.promotionHold[id] = nil
                        if self.layout.zoomedPane != id { self.zoom(id) }
                    }
                },
                menu: { [weak self] in
                    [
                        (Localized.text("Open full"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.openFull(id) }
                        }),
                        (Localized.text("Keep live"),
                            self?.pinned.contains(id) == true ? "✓" : nil, { [weak self] in
                                Gtk.onMain { [weak self] in self?.togglePin(id) }
                            }),
                        (Localized.text("Pause this pane"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.togglePark(id) }
                        }),
                        (titles("split.zoom"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.zoom(id) }
                        }),
                        (titles("split.promote"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in
                                guard let self else { return }
                                self.layout.focus(id)
                                _ = self.perform(.promoteSplit)
                            }
                        }),
                        (titles("split.close"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.close(id) }
                        }),
                    ]
                }))
    }
}
