import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// `TAILSCODE_DRIVE="2000:open=1;4000:up=400;6000:jump"` — timed UI actions for headless
    /// validation, driving the same code paths a person's clicks and wheel do.
    func installDriver() {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TAILSCODE_DRIVE_FILE"], !path.isEmpty { watchDriveFile(path) }
        guard let script = environment["TAILSCODE_DRIVE"] else { return }
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let delay = UInt32(parts[0]) else { continue }
            let action = String(parts[1])
            Gtk.after(delay) { [weak self] in self?.drive(action: action, delay: delay) }
        }
    }

    /// `TAILSCODE_DRIVE_FILE=<path>`: every line appended to the file is run as one drive verb the
    /// moment it is seen, so a headless session can steer the app it already has — `brain=hover=4`,
    /// then a shot — instead of restarting it with a longer script.
    func watchDriveFile(_ path: String) {
        let offset = DriveFileOffset()
        offset.value = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        lookAtDriveFile(path, offset)
    }

    func lookAtDriveFile(_ path: String, _ offset: DriveFileOffset) {
        Gtk.after(150) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if let data = FileManager.default.contents(atPath: path), data.count > offset.value {
                    let fresh = data.suffix(from: offset.value)
                    offset.value = data.count
                    for line in String(decoding: fresh, as: UTF8.self).split(separator: "\n") {
                        let action = line.trimmingCharacters(in: .whitespaces)
                        if !action.isEmpty { self.drive(action: action, delay: 0) }
                    }
                }
                self.lookAtDriveFile(path, offset)
            }
        }
    }

    final class DriveFileOffset: @unchecked Sendable {
        var value = 0
    }

    /// One drive verb, from a timed script or from the drive file.
    func drive(action: String, delay: UInt32) {
        FileHandle.standardOutput.write(Data("DRIVE \(delay) \(action)\n".utf8))
        let pieces = action.split(separator: "=", maxSplits: 1)
        let verb = String(pieces.first ?? "")
        let argument = pieces.count > 1 ? String(pieces[1]) : ""
        switch verb {
        case "open":
            if let index = Int(argument), index < self.visible.count {
                self.openItem(self.visible[index])
            }
        case "openid":
            if let match = self.visibleEntries.first(where: { $0.session.id == argument }) {
                self.open(match)
            } else {
                let ids = self.visibleEntries.prefix(6).map { $0.session.id }
                FileHandle.standardOutput.write(
                    Data(
                        "OPENID missing \(argument) of \(self.visible.count): \(ids.joined(separator: ","))\n"
                            .utf8))
            }
        case "openlink":
            self.openConnectLink(argument)
        case "frpaste", "frchoose", "frback", "frconfirm", "frconnect", "fragent", "frhanded",
            "frpassword", "frretry", "frstate", "frlater":
            FirstRunDialog.drive(verb, argument)
        case "frwelcome":
            self.stageWelcome(argument)
        case "notice":
            if argument == "test" || argument.isEmpty {
                Notifier.shared.sendTest()
            } else {
                NoticeDemo.raise(argument)
            }
        case "workflowdemo":
            self.activePane.driverWorkflowDemo(argument)
        case "workflowmark":
            self.activePane.reportWorkflowMark()
        case "resumedemo":
            self.activePane.driverResumeDemo(argument.isEmpty ? "waiting" : argument)
        case "resumestate":
            self.activePane.reportResumeState()
        case "tablestream":
            self.activePane.driverTableStreamDemo()
        case "tabledemo":
            self.activePane.driverTableDemo()
        case "codedemo":
            self.activePane.driverCodeDemo()
        case "furnituredemo":
            self.activePane.driverFurnitureDemo(argument)
        case "landingchat":
            self.activePane.driverFurnitureDemo(argument, landing: true)
        case "cutoffdemo":
            self.activePane.driverInterruptedDemo(
                argument.isEmpty ? "busy" : argument)
        case "carrydemo":
            self.activePane.driverCarryDemo()
        case "retrydemo":
            self.activePane.driverRetryDemo(argument)
        case "undodemo":
            self.activePane.driverUndoDemo(argument)
        case "restoredemo":
            self.activePane.driverRestoreDemo()
        case "designui":
            self.presentDesignPreflight(for: self.activePane, argument: argument)
        case "designdemo":
            DesignBoardWindow.present(
                board: DesignDemo.board, pages: DesignDemo.pages, parent: self.window,
                send: { [weak self] prompt in
                    Gtk.onMain { [weak self] in self?.activePane.sendComposed(prompt) }
                },
                notice: { _ in })
        case "compactdemo":
            self.activePane.driverCompactionDemo(argument.isEmpty ? "done" : argument)
        case "compact":
            self.activePane.requestCompaction(instruction: argument)
        case "compactui":
            Dialogs.compactPreflight(
                parent: self.window,
                facts: CompactPreflight.make(
                    state: self.activePane.lastState,
                    showsInstruction: argument != "noinstruction"),
                draft: nil
            ) { _ in
                FileHandle.standardOutput.write(Data("COMPACT confirmed\n".utf8))
            }
        case "orb":
            FileHandle.standardOutput.write(Data("ORB \(self.orb.stateLine)\n".utf8))
        case "mark":
            if let index = Int(argument), index < self.visible.count {
                self.mark(item: self.visible[index], shifted: false)
            } else {
                self.toggleMarkAtCursor()
            }
            FileHandle.standardOutput.write(Data("MARK \(self.marksSummary)\n".utf8))
        case "markrange":
            guard let index = Int(argument), index < self.visible.count else { return }
            self.mark(item: self.visible[index], shifted: true)
            FileHandle.standardOutput.write(Data("MARK \(self.marksSummary)\n".utf8))
        case "markall":
            self.toggleMarkAll()
            FileHandle.standardOutput.write(Data("MARK \(self.marksSummary)\n".utf8))
        case "bulk":
            self.perform(bulk: BulkChatAction(rawValue: argument) ?? .archive)
            FileHandle.standardOutput.write(Data("BULK \(self.marksSummary)\n".utf8))
        case "marksplit":
            self.openMarkedSplit(SplitArrangement(rawValue: argument) ?? .grid)
            FileHandle.standardOutput.write(
                Data("MARKSPLIT \(self.splitHost.paneCount)\n".utf8))
        case "opentab":
            if let item = self.visible.first(where: { $0.isTab }) {
                self.openItem(item)
            }
            FileHandle.standardOutput.write(
                Data("OPENTAB \(self.splitHost.paneCount)\n".utf8))
        case "stopwork":
            if let entry = self.activePane.entry, let backend = self.activePane.backend {
                self.stopBackgroundWork(entry, on: backend) { word in
                    FileHandle.standardOutput.write(Data("STOPWORK \(word)\n".utf8))
                }
            } else {
                FileHandle.standardOutput.write(Data("STOPWORK no chat is open\n".utf8))
            }
        case "archive":
            if let entry = self.activePane.entry {
                let word = self.toggleArchived(entry)
                let listed = self.visibleEntries.contains { $0.session.id == entry.session.id }
                FileHandle.standardOutput.write(
                    Data("ARCHIVE listed=\(listed) \(word)\n".utf8))
            }
        case "sections":
            let described = self.visible.map { "\($0.state):\($0.title)" }
                .joined(separator: " | ")
            FileHandle.standardOutput.write(Data("SECTIONS \(described)\n".utf8))
        case "gallery":
            self.activePane.driverOpenGallery()
        case "viewer":
            self.driveViewer(argument)
        case "newchat":
            Task { [weak self] in
                let profiles = await ServerDirectory.shared.profiles()
                guard let profile = profiles.first else { return }
                Gtk.onMain { [weak self] in
                    self?.createChat(
                        on: profile, directory: argument.isEmpty ? nil : argument)
                }
            }
        case "newchatui":
            self.presentNewChat()
        case "pscope":
            if let index = Int(argument), index < self.visible.count,
                let lead = self.visible[index].lead
            {
                self.setProjectScope(ProjectScope(of: lead.entry))
            } else {
                self.toggleProjectScope()
            }
        case "ask":
            self.presentQuickAsk()
        case "summon":
            self.summonQuickAsk()
        case "asktype":
            QuickAskWindow.open?.driveType(argument)
        case "askgo":
            QuickAskWindow.open?.driveGo()
        case "askstarter":
            QuickAskWindow.open?.driveStarter((Int(argument) ?? 1) - 1)
        case "askpick":
            QuickAskWindow.open?.drivePick((Int(argument) ?? 1) - 1)
        case "up":
            self.activePane.scroll(by: -(Double(argument) ?? 200))
        case "down":
            self.activePane.scroll(by: Double(argument) ?? 200)
        case "jump":
            self.activePane.jumpToBottom()
        case "contentheight":
            FileHandle.standardOutput.write(
                Data("CONTENTHEIGHT \(self.activePane.contentHeightSummary)\n".utf8))
        case "servers":
            self.presentServers()
        case "updates":
            self.presentUpdates()
        case "settings":
            self.presentSettings()
        case "models":
            ModelChooserWindow.present(
                sources: ModelChooserDemo.sources(), selected: ModelChooserDemo.selected,
                parent: self.window, quotas: ModelChooserDemo.quotas(),
                recents: ModelChooserDemo.recents
            ) { pick in
                FileHandle.standardOutput.write(
                    Data("MODELS \(pick.serverName)/\(pick.modelName)\n".utf8))
            }
        case "usage":
            self.presentUsage()
        case "usagestate":
            self.driverUsageState(argument)
        case "analytics":
            AnalyticsPanel.present(parent: self.sidebarPane)
        case "share":
            if let analytics = ShareFixtures.analytics(named: argument.isEmpty ? "rich" : argument) {
                ShareCardDialog.present(analytics, parent: self.window)
            }
        case "type":
            let pane = self.activePane
            pane.driverType(argument)
            let names = pane.completionMatches.prefix(5).map(\.name)
            FileHandle.standardOutput.write(
                Data(
                    "COMPLETION \(pane.completionMatches.count) [\(names.joined(separator: ","))] shown=\(pane.completionShown)\n"
                        .utf8))
            FileHandle.standardOutput.write(
                Data("AURA \(pane.auraActive ? "on" : "off")\n".utf8))
        case "send":
            self.activePane.sendFromComposer()
            FileHandle.standardOutput.write(
                Data("SEND \(self.activePane.freshCanvasReading)\n".utf8))
        case "canvas":
            FileHandle.standardOutput.write(
                Data("CANVAS \(self.activePane.freshCanvasReading)\n".utf8))
        case "tab":
            _ = self.activePane.handleComposerKey(keyval: Keymap.tab, state: 0)
            FileHandle.standardOutput.write(
                Data("COMPOSER \"\(self.activePane.composerText())\"\n".utf8))
        case "term":
            _ = self.perform(.toggleTerminal)
            Gtk.after(300) { [weak self] in
                guard let self, let window = self.window else { return }
                FileHandle.standardOutput.write(
                    Data("TERMFOCUS \(self.terminal.ownsFocus(in: window))\n".utf8))
            }
        case "bandagents":
            self.activePane.bandState.openMenu(id: "agents")
        case "agents", "agents-hour", "agent-peek", "agents-close", "agents-size", "agents-state",
            "agents-stress":
            self.driveAgents(verb, argument)
        case "party":
            self.presentPartyDemo(editing: false)
        case "partyedit":
            self.presentPartyDemo(editing: true)
        case "chatchooser":
            self.activePane.openModelChooser()
        case "partyfill":
            self.activePane.openPartyFill(slot: (Int(argument) ?? 6) - 1)
        case "partyroom":
            self.presentPartyRoomDemo()
        case "partyclose":
            self.demoParty?.close()
        case "dial":
            self.presentDialDemo()
        case "dkey":
            self.pressDialDemo(argument)
        case "dtype":
            self.demoDial?.search(argument)
            self.reportDialDemo("DTYPE \(argument)")
        case "toast":
            self.toast(Localized.text("Command copied"))
        case "reader":
            self.activePane.context.presentText?(
                "Compaction summary", "COMPACTED · 527.8k → 24.8k · 2m 4s",
                """
                ## 1. Primary Request and Intent

                The user asked for a **full performance remaster** of the Linux app, with
                *proper* theming and `TranscriptRow` rebuilt off-main.

                - Tail-first fill so the visible screenful lands in one frame
                - Disk-cached images keyed by their server path
                - A pin that runs outside layout, never inside `changed`

                ```swift
                func schedulePinCorrector() {
                    Gtk.onMain { self.pinToBottom() }
                }
                ```

                > A frozen frame is worse than a slow answer.

                See [the docs](https://docs.gtk.org/gtk4/) for `GtkViewport` details.
                """,
                false)
        case "scale":
            Preferences.setScale((Double(argument) ?? 100) / 100, for: .prose)
            Preferences.setScale((Double(argument) ?? 100) / 100, for: .mono)
            MatrixTheme.install()
            self.applyLayoutPreferences()
        case "soakopen":
            self.soakOpen(SplitArrangement(rawValue: argument) ?? .grid, attempts: 30)
        case "soaksend":
            self.soakSend()
        case "soakhammer":
            self.soakHammer(seconds: Int(argument) ?? 60)
        case "soakstats":
            Soak.report()
        case "soaktrim":
            Soak.trimAndReport()
        case "split":
            _ = self.perform(.splitPane(argument == "down" ? .vertical : .horizontal))
        case "sfocus":
            _ = self.perform(.focusSplit(SplitDirection(rawValue: argument) ?? .right))
        case "sclose":
            _ = self.perform(.closeSplit)
        case "szoom":
            _ = self.perform(.zoomSplit)
        case "sxchg":
            _ = self.perform(.exchangeSplit)
        case "seq":
            _ = self.perform(.equalizeSplits)
        case "chord":
            self.driveChords(argument)
        case "order":
            self.reportOrder("ORDER")
        case "panemenu":
            let described = self.paneMenuSections().map { section in
                let rows = section.rows.map {
                    "\($0.title)\($0.detail.map { " [\($0)]" } ?? "")\($0.on ? " *" : "")"
                }
                return "\(section.heading ?? "-"): \(rows.joined(separator: " | "))"
            }.joined(separator: " || ")
            FileHandle.standardOutput.write(Data("PANEMENU \(described)\n".utf8))
        case "divkey":
            self.driveDividerKey(argument)
        case "divinfo":
            let count = self.splitHost.layout.splitIDs.count
            let lines = (0..<count).map { self.splitHost.dividerSummary($0) }
            FileHandle.standardOutput.write(
                Data("DIVIDERS \(count) \(lines.joined(separator: " | "))\n".utf8))
        case "pdrag", "pdrop":
            self.drivePaneDrag(argument, drop: verb == "pdrop")
        case "full":
            if let window = self.window { gtk_window_fullscreen(ptr(window)) }
        case "handles":
            guard let window = self.window else { break }
            var shadowX: Double = 0
            var shadowY: Double = 0
            gtk_native_get_surface_transform(op(window), &shadowX, &shadowY)
            let centers = self.splitHost.handleCenters(in: window)
                .map { ($0.0, $0.1 + shadowX, $0.2 + shadowY) }
                .map { String(format: "%.0f,%.0f", $0.1, $0.2) }
                .sorted()
            FileHandle.standardOutput.write(
                Data(
                    "HANDLES \(centers.count) \(centers.joined(separator: " ")) window=\(gtk_widget_get_width(window))x\(gtk_widget_get_height(window))\n"
                        .utf8))
        case "geom":
            guard let window = self.window else { break }
            var shadowX: Double = 0
            var shadowY: Double = 0
            gtk_native_get_surface_transform(op(window), &shadowX, &shadowY)
            let described = self.splitHost.orderedPanes.enumerated().map {
                index, pane -> String in
                let bounds = Gtk.bounds(of: pane.frame, in: window) ?? (0, 0, 0, 0)
                let composer =
                    Gtk.bounds(of: pane.composerScroller, in: window) ?? (0, 0, 0, 0)
                return String(
                    format: "%d(%.0f,%.0f %.0fx%.0f composer=%.0f,%.0f)", index,
                    bounds.x + shadowX, bounds.y + shadowY, bounds.width, bounds.height,
                    composer.x + composer.width / 2 + shadowX,
                    composer.y + composer.height / 2 + shadowY)
            }.joined(separator: " ")
            FileHandle.standardOutput.write(
                Data("GEOM \(described) canvas=\(self.splitHost.canvasSummary)\n".utf8))
        case "chooser":
            FileHandle.standardOutput.write(
                Data("CHOOSER \(self.activePane.chooserSummary ?? "-")\n".utf8))
        case "watch":
            let pane = self.activePane
            pane.showVideo(VideoTarget.classify(argument))
            FileHandle.standardOutput.write(
                Data("WATCH \(pane.videoSummary ?? "-")\n".utf8))
        case "browse":
            let pane = self.activePane
            pane.showWeb(WebTarget.classify(argument))
            FileHandle.standardOutput.write(
                Data("BROWSE \(pane.webSummary ?? "-")\n".utf8))
        case "preview":
            let pane = self.activePane
            pane.showPreview(Self.previewTarget(from: argument))
            FileHandle.standardOutput.write(
                Data("PREVIEW \(pane.previewSummary ?? "-")\n".utf8))
        case "previewsum":
            FileHandle.standardOutput.write(
                Data("PREVIEWSUM \(self.activePane.previewSummary ?? "-")\n".utf8))
        case "previewlens":
            let pane = self.activePane
            if let lens = PreviewLens(rawValue: argument) { _ = pane.preview?.chooseLens(lens) }
            FileHandle.standardOutput.write(
                Data("PREVIEWLENS \(pane.previewLensSummary ?? "-")\n".utf8))
        case "lens":
            let pane = self.activePane
            let accepted = pane.preview?.driveLens(argument) ?? false
            FileHandle.standardOutput.write(
                Data("LENS \(accepted) \(pane.previewLensSummary ?? "-")\n".utf8))
        case "previewfixture":
            let pane = self.activePane
            pane.drivePreviewFixture(argument)
            FileHandle.standardOutput.write(
                Data("PREVIEWFIXTURE \(pane.previewSummary ?? "-")\n".utf8))
        case "draw":
            let pane = self.activePane
            pane.showDraw(
                argument.isEmpty ? nil : ImageGenEndpoint(address: argument))
            FileHandle.standardOutput.write(
                Data("DRAW \(pane.isDrawing ? pane.drawEndpoint?.address ?? "-" : "-")\n"
                    .utf8))
        case "drawtype":
            self.activePane.draw?.driverType(argument)
            let typed = self.activePane.draw?.promptText ?? ""
            FileHandle.standardOutput.write(
                Data("DRAWTYPE \(typed.isEmpty ? "-" : typed)\n".utf8))
        case "drawenhance":
            self.activePane.draw?.driverEnhance()
            FileHandle.standardOutput.write(
                Data("DRAWENHANCE \(self.activePane.draw?.studio.helper?.chip ?? "-")\n"
                    .utf8))
        case "drawgo":
            self.activePane.draw?.driverSubmit()
            FileHandle.standardOutput.write(
                Data("DRAWGO \(self.activePane.draw?.slot.isBusy ?? false)\n".utf8))
        case "drawsum":
            let lines = self.activePane.draw?.slot.pictures.map {
                ($0.name, $0.prompt)
            } ?? []
            FileHandle.standardOutput.write(
                Data("DRAWSUM \(lines)\n".utf8))
        case "image":
            let studio = self.presentImageStudio()
            FileHandle.standardOutput.write(
                Data("IMAGE \(studio == nil ? "-" : ImageStudio.shared.endpoint.address)\n"
                    .utf8))
        case "imagetype":
            StudioSheet.current?.driverType(argument)
            FileHandle.standardOutput.write(
                Data("IMAGETYPE \(argument.isEmpty ? "-" : argument)\n".utf8))
        case "imageengine":
            if let engine = ImageGenEngine(rawValue: argument) {
                ImageStudio.shared.choose(engine: engine)
            }
            FileHandle.standardOutput.write(
                Data("IMAGEENGINE \(ImageStudio.shared.slot.engine.rawValue)\n".utf8))
        case "imageaspect":
            if let aspect = ImageGenAspect(rawValue: argument) {
                ImageStudio.shared.choose(aspect: aspect)
            }
            FileHandle.standardOutput.write(
                Data("IMAGEASPECT \(ImageStudio.shared.slot.aspect.rawValue)\n".utf8))
        case "imageattach":
            if let window = StudioSheet.current {
                window.driverAttach(argument)
            } else {
                self.activePane.draw?.attachFiles([argument])
            }
            FileHandle.standardOutput.write(Data("IMAGEATTACH \(argument)\n".utf8))
        case "imagego":
            StudioSheet.current?.driverSubmit()
            FileHandle.standardOutput.write(
                Data("IMAGEGO \(ImageStudio.shared.isPainting)\n".utf8))
        case "imageenhance":
            StudioSheet.current?.driverEnhance()
            FileHandle.standardOutput.write(
                Data("IMAGEENHANCE \(ImageStudio.shared.helper?.chip ?? "-")\n".utf8))
        case "imageuse":
            StudioSheet.current?.driverUseRewrite()
            FileHandle.standardOutput.write(Data("IMAGEUSE\n".utf8))
        case "imagerewrite":
            FileHandle.standardOutput.write(
                Data("IMAGEREWRITE \(StudioSheet.current?.rewriteSummary ?? "-") sketch=\(ImageStudio.shared.previewTexture != 0) anim=\(RepeatingMotion.allowed) arrival=\(StudioSheet.current?.arrivalSummary ?? "-")\n".utf8))
        case "studio":
            let line = StudioSheet.current?.studioSummary
                ?? self.activePane.draw?.studioSummary ?? "-"
            FileHandle.standardOutput.write(Data("STUDIO \(line)\n".utf8))
        case "imagesum":
            FileHandle.standardOutput.write(
                Data("IMAGESUM \(ImageStudio.shared.summary)\n".utf8))
        case "sheet":
            let sheet = self.studioSheet
            switch argument {
            case "image": sheet?.show(.image)
            case "video": sheet?.show(.video)
            case "close": sheet?.dismiss()
            case "release": sheet?.release()
            default:
                if let presence = Double(argument.replacingOccurrences(of: "hold", with: "")) {
                    sheet?.hold(at: presence)
                }
            }
            FileHandle.standardOutput.write(
                Data("SHEET \(sheet?.summary ?? "-")\n".utf8))
        case "forge":
            let forge = self.presentForge()
            if !argument.isEmpty { forge.demonstrate(argument) }
            FileHandle.standardOutput.write(Data("FORGE \(forge.forgeSummary)\n".utf8))
        case "beta":
            self.driveBeta(argument, parent: self.window)
        case "range":
            self.driveRange(argument, parent: self.window)
        case "clock":
            self.driveClock(argument)
        case "setup":
            self.driveSetup(argument)
        case "brain":
            self.driveBrain(argument)
        case "call":
            self.driveCall(argument)
        case "reach":
            self.driveReach(argument)
        case "motion":
            self.driveMotion(argument)
        case "callshow":
            self.driveCallShow(argument)
        case "callnarrow":
            self.driveCallNarrow(argument)
        case "delegate":
            _ = self.presentDelegate(host: argument.isEmpty ? nil : argument)
        case "dcompose":
            DelegateWindow.current?.presentComposer()
        case "dhandoff":
            let demo = DelegateDemo.hosts.first { $0.hasPrefix("studio") } ?? ""
            self.presentDelegate(
                handoff: DelegateHandoff(
                    host: demo, serverName: "studio", goal: argument, repo: "/Users/demo/dev/pulse-server"))
        case "drun":
            if argument.isEmpty {
                DelegateWindow.current?.openFirstRun()
            } else {
                DelegateWindow.current?.openRun(id: argument)
            }
        case "fring":
            if !argument.isEmpty { ForgeRunner.shared.demonstrate(argument) }
            FileHandle.standardOutput.write(
                Data("RING \(self.videoRing?.reading ?? "-") \(ForgeRunner.shared.light)\n".utf8))
        case "fstate":
            StudioSheet.current?.demonstrate(argument)
            FileHandle.standardOutput.write(
                Data("FORGE \(StudioSheet.current?.forgeSummary ?? "-")\n".utf8))
        case "ftype":
            StudioSheet.current?.describe(argument)
            FileHandle.standardOutput.write(
                Data("FORGE \(StudioSheet.current?.forgeSummary ?? "-")\n".utf8))
        case "fsum":
            FileHandle.standardOutput.write(
                Data("FORGE \(StudioSheet.current?.forgeSummary ?? "-")\n".utf8))
        case "fenhance", "fuse", "fframe", "fextend", "fsound", "fplay", "fverb":
            StudioSheet.current?.drive(verb, argument)
            FileHandle.standardOutput.write(
                Data("FORGE \(StudioSheet.current?.forgeSummary ?? "-")\n".utf8))
        case "fkey":
            let keyval: UInt32
            var state: UInt32 = 0
            switch argument {
            case "up": keyval = Keymap.up
            case "down": keyval = Keymap.down
            case "enter": keyval = Keymap.enter
            case "tab": keyval = Keymap.tab
            case "esc": keyval = Keymap.escape
            case "render": keyval = 0x67; state = KeyChord.controlMask
            case "stop": keyval = 0x63; state = KeyChord.controlMask
            case "reroll": keyval = 0x72; state = KeyChord.controlMask
            default: keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            }
            var handled = false
            if let chord = KeyChord.canonical(keyval: keyval, state: state) {
                handled = StudioSheet.current?.handleChord(chord) ?? false
            }
            FileHandle.standardOutput.write(
                Data(
                    "FKEY \(argument) handled=\(handled) \(StudioSheet.current?.forgeSummary ?? "-")\n"
                        .utf8))
        case "web":
            let described = self.splitHost.orderedPanes.enumerated().map {
                index, pane in "\(index):\(pane.webSummary ?? "chat")"
            }.joined(separator: " | ")
            FileHandle.standardOutput.write(Data("WEB \(described)\n".utf8))
        case "wkey":
            let keyval: UInt32
            var state: UInt32 = 0
            switch argument {
            case "back": keyval = 0xFF51; state = KeyChord.altMask
            case "forward": keyval = 0xFF53; state = KeyChord.altMask
            case "reload": keyval = 0x72; state = KeyChord.controlMask
            case "address": keyval = 0x6C; state = KeyChord.controlMask
            default: keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            }
            var handled = false
            if let chord = KeyChord.canonical(keyval: keyval, state: state) {
                handled = self.activePane.handleWebChord(chord)
            }
            FileHandle.standardOutput.write(
                Data(
                    "WKEY \(argument) handled=\(handled) \(self.activePane.webSummary ?? "-")\n"
                        .utf8))
        case "video":
            let described = self.splitHost.orderedPanes.enumerated().map {
                index, pane in "\(index):\(pane.videoSummary ?? "chat")"
            }.joined(separator: " | ")
            FileHandle.standardOutput.write(Data("VIDEO \(described)\n".utf8))
        case "accounts":
            let described = WatchAccounts.rows().map {
                "\($0.title)=\($0.actionTitle)[\($0.detail)]"
            }.joined(separator: " | ")
            FileHandle.standardOutput.write(Data("ACCOUNTS \(described)\n".utf8))
        case "signin":
            let source = MediaSource(rawValue: argument) ?? .twitch
            WatchSignInDialog.present(parent: self.window, source: source) {}
            FileHandle.standardOutput.write(
                Data("SIGNIN \(source.rawValue) opened\n".utf8))
        case "board":
            FileHandle.standardOutput.write(
                Data("BOARD \(self.activePane.watchBoardSummary ?? "-")\n".utf8))
        case "bkey":
            let keyval: UInt32
            var state: UInt32 = 0
            switch argument {
            case "up": keyval = Keymap.up
            case "down": keyval = Keymap.down
            case "enter": keyval = Keymap.enter
            case "tab": keyval = Keymap.tab
            case "esc": keyval = Keymap.escape
            case "follow": keyval = 0x66; state = KeyChord.controlMask
            case "reload": keyval = 0x72; state = KeyChord.controlMask
            default: keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            }
            var handled = false
            if let chord = KeyChord.canonical(keyval: keyval, state: state) {
                handled = self.activePane.handleWatchChord(chord)
            }
            FileHandle.standardOutput.write(
                Data(
                    "BKEY \(argument) handled=\(handled) \(self.activePane.watchBoardSummary ?? "-")\n"
                        .utf8))
        case "btype":
            self.activePane.driveWatchQuery(argument)
            FileHandle.standardOutput.write(
                Data("BTYPE \(self.activePane.watchBoardSummary ?? "-")\n".utf8))
        case "vkey":
            let keyval = argument == "space"
                ? UInt32(0x20)
                : (argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0)
            var handled = false
            if let chord = KeyChord.canonical(keyval: keyval, state: 0) {
                handled = self.activePane.handleVideoChord(chord)
            }
            FileHandle.standardOutput.write(
                Data(
                    "VKEY \(argument) handled=\(handled) \(self.activePane.videoSummary ?? "-")\n"
                        .utf8))
        case "ckey":
            let keyval: UInt32
            switch argument {
            case "enter": keyval = Keymap.enter
            case "esc": keyval = Keymap.escape
            case "up": keyval = Keymap.up
            case "down": keyval = Keymap.down
            default:
                keyval = argument.unicodeScalars.first.map { UInt32($0.value) } ?? 0
            }
            if let chord = KeyChord.canonical(keyval: keyval, state: 0) {
                let handled = self.activePane.handleChooserChord(chord)
                FileHandle.standardOutput.write(
                    Data(
                        "CKEY \(argument) handled=\(handled) \(self.activePane.chooserSummary ?? "-")\n"
                            .utf8))
            }
        case "drag", "drop":
            let fields = argument.split(separator: ",").map(String.init)
            let index = Int(fields.first ?? "") ?? 0
            let u = Double(fields.count > 1 ? fields[1] : "0.5") ?? 0.5
            let v = Double(fields.count > 2 ? fields[2] : "0.5") ?? 0.5
            let sessionID = fields.count > 3 ? fields[3] : self.entries.first?.session.id
            let panes = self.splitHost.orderedPanes
            guard panes.indices.contains(index),
                let id = sessionID,
                let entry = self.entries.first(where: { $0.session.id.hasPrefix(id) })
            else {
                FileHandle.standardOutput.write(Data("DROP no-target\n".utf8))
                break
            }
            let pane = panes[index]
            let payload = PaneDragPayload(
                profileID: entry.profileID, sessionID: entry.session.id)
            let x = u * Double(gtk_widget_get_width(pane.frame))
            let y = v * Double(gtk_widget_get_height(pane.frame))
            if verb == "drag" {
                self.splitHost.hover(pane, payload: payload, x: x, y: y)
                FileHandle.standardOutput.write(
                    Data("DRAG \(self.splitHost.dropSummary)\n".utf8))
            } else {
                let took = self.splitHost.receiveDrop(payload.encoded, on: pane.id, x: x, y: y)
                FileHandle.standardOutput.write(
                    Data("DROP took=\(took) panes=\(self.splitHost.paneCount)\n".utf8))
            }
        case "splits":
            let layout = self.splitHost.layout
            let frames = layout.frames()
            let described = layout.paneIDs.enumerated().map { index, id -> String in
                let frame = frames[id] ?? SplitRect(x: 0, y: 0, width: 0, height: 0)
                let mark = id == layout.focusedPane ? "*" : ""
                let session = self.splitHost.panes[id]?.sessionID?.prefix(8) ?? "-"
                return String(
                    format: "%d%@(%@ %.2f,%.2f %.2fx%.2f)", index, mark,
                    String(session), frame.x, frame.y, frame.width, frame.height)
            }.joined(separator: " ")
            FileHandle.standardOutput.write(
                Data(
                    "SPLITS \(layout.paneCount) zoom=\(layout.zoomedPane != nil) region=\(self.focused) \(described)\n"
                        .utf8))
        case "stall":
            let milliseconds = UInt32(argument) ?? 4000
            FileHandle.standardOutput.write(Data("STALL \(milliseconds)ms\n".utf8))
            usleep(milliseconds * 1000)
        case "pressure":
            let pressure: HostPressure =
                switch argument {
                case "critical": .critical
                case "strained": .strained
                default: .nominal
                }
            Seatbelts.shared.inject(pressure)
            FileHandle.standardOutput.write(
                Data("PRESSURE \(pressure.code) level=\(Seatbelts.shared.level.rawValue)\n".utf8))
        case "shed":
            Seatbelts.shared.force(Int(argument).flatMap(ShedLevel.init(rawValue:)))
            FileHandle.standardOutput.write(
                Data("SHED level=\(Seatbelts.shared.level.rawValue)\n".utf8))
        case "flight":
            let text = Seatbelts.shared.flightText(last: Int(argument) ?? 12)
            FileHandle.standardOutput.write(Data(("FLIGHT\n" + text).utf8))
        case "restore":
            FileHandle.standardOutput.write(
                Data(
                    "RESTORE parked=\(self.parkedBindings.count) banner=\(self.restoreBanner?.isShown ?? false) waiting=\(self.readyToWake.count)\n"
                        .utf8))
        case "resume":
            self.resumeParked(all: argument != "one")
        case "quit":
            self.quitForUpdate()
        case "state":
            let pane = self.activePane
            let adjustment = pane.transcriptScroller.flatMap {
                gtk_scrolled_window_get_vadjustment(op($0))
            }
            let value = adjustment.map { gtk_adjustment_get_value($0) } ?? -1
            let upper = adjustment.map {
                gtk_adjustment_get_upper($0) - gtk_adjustment_get_page_size($0)
            } ?? -1
            FileHandle.standardOutput.write(
                Data(
                    "STATE follows=\(pane.followsBottom) rows=\(pane.renderedRows.count)/\(pane.lastFullRows.count) value=\(Int(value)) bottom=\(Int(upper))\n"
                    .utf8))
        default:
            if !self.driveTiles(verb, argument) { self.driveLive(verb, argument) }
        }
    }
}
