import AVFoundation
import AVKit
import CodingAgentKit
import MidgarCore
import Photos
import TailscodeCore
import UIKit

/// A video an agent named, at the size of the phone in the system's own player: scrubbing, AirPlay,
/// speed and the full-screen gesture are all things it already has. What it adds is what a chat
/// needs of a player (Crucible's lessons): Picture in Picture, so the clip keeps playing small
/// while the person answers it, and taking the player away again when it goes small; a clip of a
/// few seconds loops like a picture that moves; a longer one opens where it was left and the place
/// it is left at is kept. Its name is the title the lock screen and AirPlay show.
@MainActor
enum NamedVideoTheatre {
    /// The player that went small, held while it plays in Picture in Picture: the screen that
    /// presented it may be gone by the time the person asks for it back.
    private static var floating: NamedVideoController?

    static func present(
        _ ready: NamedMediaStore.Ready, file: FileReference, from presenter: UIViewController
    ) {
        NamedMediaStore.shared.stop()
        floating?.player?.pause()
        floating = nil
        ClipAudio.makeAudible()
        let controller = NamedVideoController(ready: ready, file: file)
        controller.home = presenter
        presenter.frontmostPresented.present(controller, animated: true) { controller.player?.play() }
    }

    static func keep(_ controller: NamedVideoController) { floating = controller }

    static func release(_ controller: NamedVideoController) {
        if floating === controller { floating = nil }
    }
}

final class NamedVideoController: AVPlayerViewController, @preconcurrency AVPlayerViewControllerDelegate {
    private let key: String
    private let duration: Double?
    private let looping: Bool
    private var looper: AVPlayerLooper?
    private var inPicture = false
    weak var home: UIViewController?

    init(ready: NamedMediaStore.Ready, file: FileReference) {
        key = NamedMediaStore.key(file)
        duration = ready.duration
        looping = MediaLoop.loops(duration: ready.duration)
        super.init(nibName: nil, bundle: nil)
        let item = AVPlayerItem(url: ready.source)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = MediaTileReading.name(of: file) as NSString
        title.extendedLanguageTag = "und"
        item.externalMetadata = [title]
        if looping {
            let queue = AVQueuePlayer()
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
        } else {
            let single = AVPlayer(playerItem: item)
            if let start = MediaPlayhead.start(for: key) {
                single.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
            player = single
        }
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        delegate = self
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed, !inPicture else { return }
        keepPlace()
        player?.pause()
    }

    private func keepPlace() {
        guard !looping, let player else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        MediaPlayhead.keep(seconds, of: duration, for: key)
    }

    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(
        _ playerViewController: AVPlayerViewController
    ) -> Bool { true }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPicture = true
        NamedVideoTheatre.keep(self)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPicture = false
        guard presentingViewController == nil else { return }
        keepPlace()
        NamedVideoTheatre.release(self)
    }

    /// The person asked for the small player back: it opens full size again from the chat it came
    /// from, or from whatever is in front when that chat is gone.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
            @escaping (Bool) -> Void
    ) {
        let presenter =
            home.flatMap { $0.viewIfLoaded?.window == nil ? nil : $0 }
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first?.rootViewController
        guard let presenter else {
            completionHandler(false)
            return
        }
        presenter.frontmostPresented.present(self, animated: true) { completionHandler(true) }
    }
}

/// A named file into the photo library, as the file the server has.
enum NamedMediaExport {
    static func saveVideoToPhotos(_ file: URL) async -> ImageExport.Outcome {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }
        let saved: Bool = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: file, options: nil)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
        if !saved { MidgarLog.error("save video to photos failed for \(file.lastPathComponent)", category: .ui) }
        return saved ? .saved : .failed
    }
}
