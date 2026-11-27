import CodingAgentKit
import MidgarCore
import TailscodeCore
import UIKit

extension ChatViewController {
    /// The cell a video or a song an agent named stands as, or nil for any other file.
    func namedMediaCell(
        _ collectionView: UICollectionView, _ indexPath: IndexPath, _ file: FileReference,
        row: ChatRow
    ) -> UICollectionViewCell? {
        if MediaMisses.isMissed(file) {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: VideoTileCell.reuseID, for: indexPath) as! VideoTileCell
            cell.showMissing(MediaTileReading.name(of: file))
            return cell
        }
        switch MediaKind.of(file) {
        case .video?:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: VideoTileCell.reuseID, for: indexPath) as! VideoTileCell
            cell.onPlay = { [weak self] file in self?.playNamedVideo(file) }
            cell.onShare = { [weak self] file, source in self?.shareNamedMedia(file, from: source) }
            cell.onSaveToPhotos = { [weak self] file in self?.saveNamedVideoToPhotos(file) }
            cell.onRetry = { [weak self] file in
                NamedMediaStore.shared.read(file, backend: self?.viewModel.backend, force: true)
            }
            cell.onResized = { [weak self] in self?.remeasureRow(row.id) }
            cell.configure(file: file, backend: viewModel.backend)
            #if DEBUG
                playForHarness(file, kind: .video)
            #endif
            return cell
        case .audio?:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: AudioLineCell.reuseID, for: indexPath) as! AudioLineCell
            cell.onRetry = { [weak self] file in
                NamedMediaStore.shared.read(file, backend: self?.viewModel.backend, force: true)
            }
            cell.onResized = { [weak self] in self?.remeasureRow(row.id) }
            cell.configure(file: file, backend: viewModel.backend)
            #if DEBUG
                playForHarness(file, kind: .audio)
            #endif
            return cell
        default:
            return nil
        }
    }

    #if DEBUG
        /// `TAILSCODE_PLAY_NAMED=video|audio`: the first named file of that kind plays once it is
        /// read, so a device nobody is holding proves playback rather than only a first frame.
        private func playForHarness(_ file: FileReference, kind: MediaKind) {
            guard ProcessInfo.processInfo.environment["TAILSCODE_PLAY_NAMED"] == kind.rawValue,
                !Self.harnessPlayed
            else { return }
            Task { [weak self] in
                for _ in 0..<40 {
                    switch NamedMediaStore.shared.state(for: file) {
                    case .ready?: break
                    case .failed?: return
                    default:
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    break
                }
                guard let self, !Self.harnessPlayed,
                    case .ready? = NamedMediaStore.shared.state(for: file)
                else { return }
                Self.harnessPlayed = true
                MidgarLog.info("harness plays \(MediaTileReading.name(of: file))", category: .ui)
                if kind == .video { self.playNamedVideo(file) } else { NamedMediaStore.shared.toggle(file) }
            }
        }

        nonisolated(unsafe) private static var harnessPlayed = false
    #endif

    /// The system player, at the size of the phone: scrubbing, AirPlay and Picture in Picture are
    /// all things it already has. A song playing in the chat stops first.
    func playNamedVideo(_ file: FileReference) {
        guard case .ready(let ready)? = NamedMediaStore.shared.state(for: file) else { return }
        NamedVideoTheatre.present(ready, file: file, from: self)
    }

    /// The clip into the photo library as the file the server has: fetched over its ticket when
    /// it is not on the phone, saved, and said so.
    func saveNamedVideoToPhotos(_ file: FileReference) {
        Task { [weak self] in
            guard let self else { return }
            guard let local = await self.localCopy(of: file) else {
                Theme.Haptics.error()
                self.presentToast(String(localized: "Couldn't save to Photos"))
                return
            }
            let outcome = await NamedMediaExport.saveVideoToPhotos(local)
            try? FileManager.default.removeItem(at: local)
            switch outcome {
            case .saved:
                Theme.Haptics.success()
                self.presentToast(String(localized: "Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self.presentToast(String(localized: "Allow photo access in Settings to save videos."))
            case .failed:
                Theme.Haptics.error()
                self.presentToast(String(localized: "Couldn't save to Photos"))
            }
        }
    }

    /// The named file on the phone under its own name: copied when it already is, fetched over
    /// its ticket when it is not.
    private func localCopy(of file: FileReference) async -> URL? {
        guard case .ready(let ready)? = NamedMediaStore.shared.state(for: file) else { return nil }
        let name = NamedMediaStore.exportName(of: file, ready: ready)
        if ready.source.isFileURL { return Self.staged(ready.source, as: name) }
        do {
            let (received, response) = try await URLSession.shared.download(from: ready.source)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard status < 400 else { throw URLError(.fileDoesNotExist) }
            return Self.staged(received, as: name, moving: true)
        } catch {
            MidgarLog.error("could not fetch \(name): \(error)", category: .ui)
            NamedMediaStore.shared.forget(file)
            return nil
        }
    }

    /// The file itself to the share sheet, where Save Video, Files and every app that takes a video
    /// already are. A ticket URL is fetched to a file first: a share sheet hands over files.
    func shareNamedMedia(_ file: FileReference, from source: UIView) {
        Task { [weak self] in
            guard let self, let staged = await self.localCopy(of: file) else { return }
            ClipExport.share(staged, from: self, source: source)
        }
    }

    /// A copy of the file under its own name, so what lands in Files or a message is called what
    /// the agent called it rather than after a cache key.
    private static func staged(_ url: URL, as name: String, moving: Bool = false) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("named-media-share", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            if moving {
                try FileManager.default.moveItem(at: url, to: target)
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
            return target
        } catch {
            return nil
        }
    }
}
