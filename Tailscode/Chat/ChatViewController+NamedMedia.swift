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
        switch MediaKind.of(file) {
        case .video?:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: VideoTileCell.reuseID, for: indexPath) as! VideoTileCell
            cell.onPlay = { [weak self] file in self?.playNamedVideo(file) }
            cell.onShare = { [weak self] file, source in self?.shareNamedMedia(file, from: source) }
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
        NamedMediaStore.shared.stop()
        ClipTheatre.present(ready.source, from: self)
    }

    /// The file itself to the share sheet, where Save Video, Files and every app that takes a video
    /// already are. A ticket URL is fetched to a file first: a share sheet hands over files.
    func shareNamedMedia(_ file: FileReference, from source: UIView) {
        guard case .ready(let ready)? = NamedMediaStore.shared.state(for: file) else { return }
        let name = MediaTileReading.name(of: file)
        guard !ready.source.isFileURL else {
            ClipExport.share(Self.staged(ready.source, as: name) ?? ready.source, from: self, source: source)
            return
        }
        Task { [weak self] in
            do {
                let (received, response) = try await URLSession.shared.download(from: ready.source)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard status < 400 else { throw URLError(.fileDoesNotExist) }
                guard let self, let staged = Self.staged(received, as: name, moving: true) else { return }
                ClipExport.share(staged, from: self, source: source)
            } catch {
                MidgarLog.error("could not fetch \(name) to share: \(error)", category: .ui)
                NamedMediaStore.shared.forget(file)
            }
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
