import AppKit
import CodingAgentKit
import MidgarCore
import TailscodeCore

extension TranscriptViewController {
    /// The transcript's side of `NamedMediaStore`: reading a named file, playing it, sharing it, and
    /// rebuilding a row when what its file is changes.
    func wireNamedMedia() {
        context.requestMedia = { [weak self] reference, force in
            NamedMediaStore.shared.read(reference, backend: self?.backend, force: force)
        }
        context.playMedia = { [weak self] reference in self?.playNamedMedia(reference) }
        context.shareMedia = { [weak self] reference, anchor in self?.shareNamedMedia(reference, from: anchor) }
        context.seekMedia = { [weak self] reference, fraction in
            NamedMediaStore.shared.toggle(reference, at: fraction)
            self?.namedSong = NamedMediaStore.shared.playingKey
        }
        guard namedMediaObserver == nil else { return }
        namedMediaObserver = NotificationCenter.default.addObserver(
            forName: NamedMediaStore.changed, object: nil, queue: .main
        ) { [weak self] note in
            guard let key = note.userInfo?[NamedMediaStore.keyInfo] as? String else { return }
            MainActor.assumeIsolated { self?.namedMediaChanged(key) }
        }
        missesObserver = NotificationCenter.default.addObserver(
            forName: MediaMisses.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isViewLoaded else { return }
                self.rowBuilder.invalidate()
                self.rebuildRows()
            }
        }
    }

    private func namedMediaChanged(_ key: String) {
        let shape: String
        switch NamedMediaStore.shared.state(for: FileReference(url: key)) {
        case .reading?: shape = "reading"
        case .ready?: shape = "ready"
        case .failed?: shape = "failed"
        case nil: shape = "none"
        }
        guard namedMediaShapes[key] != shape else { return }
        namedMediaShapes[key] = shape
        replaceRows { row in
            guard case .file(let reference, false, _) = row.kind else { return false }
            return NamedMediaStore.key(reference) == key
        }
    }

    private func playNamedMedia(_ reference: FileReference) {
        let store = NamedMediaStore.shared
        guard let kind = MediaKind.of(reference), case .ready(let ready)? = store.state(for: reference)
        else {
            store.read(reference, backend: backend, force: true)
            return
        }
        if kind == .audio {
            store.toggle(reference)
            namedSong = store.playingKey
            return
        }
        stopNamedSong()
        let name = MediaTileReading.name(of: reference)
        let key = NamedMediaStore.key(reference)
        let looping = MediaLoop.loops(duration: ready.duration)
        MediaViewer.shared.play(
            clip: ready.source, title: name, host: view.window,
            save: { [weak self] report in self?.saveNamedMedia(reference, report: report) },
            share: { [weak self] anchor in self?.shareNamedMedia(reference, from: anchor) },
            toast: context.toast,
            playback: ClipPlayback(
                loops: looping, startAt: looping ? nil : MediaPlayhead.start(for: key),
                left: { seconds in
                    if !looping { MediaPlayhead.keep(seconds, of: ready.duration, for: key) }
                }))
    }

    func stopNamedSong() {
        guard let song = namedSong else { return }
        namedSong = nil
        if NamedMediaStore.shared.playingKey == song { NamedMediaStore.shared.stop() }
    }

    /// The file itself, on this Mac under its own name: copied when it is already here, fetched
    /// over its ticket when it is not.
    private func localCopy(of reference: FileReference) async throws -> URL {
        guard case .ready(let ready)? = NamedMediaStore.shared.state(for: reference) else {
            throw URLError(.fileDoesNotExist)
        }
        let name = NamedMediaStore.exportName(of: reference, ready: ready)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("named-media-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        if ready.source.isFileURL {
            try FileManager.default.copyItem(at: ready.source, to: target)
            return target
        }
        let (received, response) = try await URLSession.shared.download(from: ready.source)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw URLError(.fileDoesNotExist) }
        try FileManager.default.moveItem(at: received, to: target)
        return target
    }

    private func shareNamedMedia(_ reference: FileReference, from anchor: NSView) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await self.localCopy(of: reference)
                StudioFiles.share(file, from: anchor)
            } catch {
                MidgarLog.error("could not fetch a named file to share: \(error)", category: .ui)
                NamedMediaStore.shared.forget(reference)
            }
        }
    }

    /// Into Downloads under the file's own name, numbered when one of that name is there already.
    private func saveNamedMedia(_ reference: FileReference, report: @escaping @MainActor (String) -> Void) {
        Task {
            guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            else {
                report(Localized.text("This Mac has no Downloads folder to write to."))
                return
            }
            do {
                let file = try await self.localCopy(of: reference)
                let target = Self.freeName(file.lastPathComponent, in: downloads)
                try FileManager.default.moveItem(at: file, to: target)
                report(Localized.text("Saved %@", target.path))
            } catch {
                report(Localized.text("Could not write %@", downloads.path))
            }
        }
    }

    private static func freeName(_ name: String, in folder: URL) -> URL {
        let first = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: first.path) else { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for number in 2..<1000 {
            let candidate = folder.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return folder.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }
}
