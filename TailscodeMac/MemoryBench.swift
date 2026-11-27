import AppKit
import CodingAgentKit
import TailscodeCore

/// `--bench memory=<session,session…>[:<settle>:<hold>]` opens the named chats of the server
/// `TAILSCODE_HOST` names, one pane each, in a borderless window parked off every screen, and says
/// what the system charges the app for them: at launch, the highest it reached while they were
/// read, once every transcript had loaded, after `<settle>` seconds (20 by default), after every
/// cache in the relief registry was given back, and after every pane was closed. Every picture the
/// transcripts name is read back through the backend and decoded, so a run says whether a picture
/// kept off the heap still draws. `<hold>` seconds (none by default) are waited with the panes
/// open and again once they are closed, with the process id printed, for `heap` and `leaks` to be
/// pointed at it. The panes' window is three wide and never composited, so its layers' surfaces
/// are the bench's own and not what a window on a screen holds.
@MainActor
enum MemoryBench {
    static func run(_ spec: String) -> Never {
        let fields = spec.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let parts = fields.split(separator: ":").map(String.init)
        let sessions = (parts.first ?? "").split(separator: ",").map(String.init)
        let settle = parts.count > 1 ? Double(parts[1]) ?? 20 : 20
        let hold = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await bench(sessions: sessions, settle: settle, hold: hold)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static var peak = 0.0
    private static var sampling = false

    private static func megabytes() -> Double {
        Double(MemoryPressure.footprintBytes() ?? 0) / 1_048_576
    }

    private static func sample() {
        guard sampling else { return }
        peak = max(peak, megabytes())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainThread.call { sample() }
        }
    }

    private static func say(_ stage: String) {
        print(String(format: "memory: %@ %.0f MB", stage, megabytes()))
    }

    /// Reads every picture the transcripts name back through the backend and decodes it, so a
    /// run says whether a picture kept off the heap still draws.
    private static func sayPictures(
        _ panes: [TranscriptViewController], backend: any CodingAgentBackend
    ) async {
        let files = panes.flatMap { $0.currentState?.messages ?? [] }.flatMap(\.parts).compactMap {
            part -> FileReference? in
            guard case .file(let file) = part.kind, file.mime?.hasPrefix("image/") == true else { return nil }
            return file
        }
        var drawn = 0
        var held = 0
        for file in files {
            held += file.url?.utf8.count ?? 0
            guard let data = try? await backend.attachmentData(file) else { continue }
            if await Task.detached(operation: { ImageStore.decode(data) != nil }).value { drawn += 1 }
        }
        print("memory: \(files.count) pictures named, \(held / 1024) KB of references held, \(drawn) read back and decoded")
    }

    private static func bench(sessions: [String], settle: Double, hold: Double) async {
        guard ProcessInfo.processInfo.environment["TAILSCODE_HOST"] != nil, !sessions.isEmpty else {
            print("memory: set TAILSCODE_HOST (and TAILSCODE_PASSWORD, TAILSCODE_BACKEND) and name the chats to open")
            return
        }
        let listed = await ServerDirectory.shared.entries().entries
        guard let profile = ServerDirectory.shared.profiles.first,
            let backend = ServerDirectory.shared.backend(for: profile)
        else {
            print("memory: no server to ask")
            return
        }
        CacheRelief.install()
        say("launch")
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 1_500, height: 950),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        let root = NSViewController()
        root.view = stack
        window.contentViewController = root
        window.setFrame(NSRect(x: -30_000, y: -30_000, width: 1_500, height: 950), display: false)
        window.orderFrontRegardless()
        var panes: [TranscriptViewController] = []
        peak = megabytes()
        sampling = true
        sample()
        for id in sessions {
            let entry =
                listed.first { $0.session.id == id }
                ?? SessionEntry(
                    profileID: profile.id, profileName: profile.name,
                    host: profile.baseURL.host ?? profile.name, backendType: profile.backend,
                    session: AgentSession(
                        id: id, agentType: profile.backend, title: id, directory: nil,
                        createdAt: Date(), updatedAt: Date(), isActive: false, model: nil))
            let pane = TranscriptViewController()
            root.addChild(pane)
            stack.addArrangedSubview(pane.view)
            pane.open(entry, backend: backend)
            pane.setFocusedPane(panes.isEmpty)
            panes.append(pane)
        }
        let began = CACurrentMediaTime()
        while CACurrentMediaTime() - began < 120,
            !panes.allSatisfy({ $0.currentState?.hasLoadedTranscript == true })
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .seconds(2))
        print(
            String(
                format: "memory: %d of %d transcripts loaded in %.1f s, %d messages, peak %.0f MB",
                panes.filter { $0.currentState?.hasLoadedTranscript == true }.count, panes.count,
                CACurrentMediaTime() - began - 2,
                panes.reduce(0) { $0 + ($1.currentState?.messages.count ?? 0) }, peak))
        say("loaded")
        try? await Task.sleep(for: .seconds(settle))
        sampling = false
        say("settled")
        print(String(format: "memory: peak %.0f MB", peak))
        await sayPictures(panes, backend: backend)
        if hold > 0 {
            print("memory: holding pid \(getpid()) for \(Int(hold)) s")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(hold))
        }
        let relieved = MemoryRelief.shared.relieve(.all)
        try? await Task.sleep(for: .seconds(3))
        say("relieved (\(relieved.joined(separator: ", ")))")
        for pane in panes {
            pane.shutdownPane()
            stack.removeArrangedSubview(pane.view)
            pane.view.removeFromSuperview()
            pane.removeFromParent()
        }
        panes = []
        try? await Task.sleep(for: .seconds(10))
        say("closed")
        if hold > 0 {
            print("memory: holding pid \(getpid()) closed for \(Int(hold)) s")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(hold))
        }
        window.orderOut(nil)
    }
}

extension TranscriptViewController {
    /// Every picture this pane's rows hold, for the bench that says whether they still draw.
    var benchPictures: [TranscriptRow.GalleryPicture] {
        lastFullRows.flatMap { row -> [TranscriptRow.GalleryPicture] in
            if case .pictures(let pictures) = row.kind { return pictures }
            return []
        }
    }
}
