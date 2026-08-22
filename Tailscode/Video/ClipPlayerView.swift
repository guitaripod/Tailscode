import AVFoundation
import AVKit
import UIKit

/// The clip, playing where it was made.
///
/// A generated video is a few seconds long, so it loops rather than ending — `AVPlayerLooper` over
/// a queue player, which repeats without the black frame a seek-on-end leaves. The layer is the
/// view's own, so nothing has to be resized by hand when the stage changes shape between a
/// landscape render and a portrait one.
@MainActor
final class ClipPlayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var url: URL?

    /// Whether the clip is heard. LTX renders audio with the picture, so a clip that came back
    /// silent is a fact about the render rather than about the player — but a card that starts
    /// talking the moment a render lands is a card nobody wants on a train, so the loop begins
    /// muted and the sound is asked for.
    private(set) var isMuted = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    /// Points the player at a clip. The same URL twice is left alone, because a stage that
    /// reconfigures on every frame off the socket would otherwise restart the clip a dozen times a
    /// second the moment it arrived.
    func show(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = isMuted
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item)
        playerLayer.player = queue
        player = queue
        queue.play()
    }

    func clear() {
        player?.pause()
        playerLayer.player = nil
        looper = nil
        player = nil
        url = nil
    }

    func setPlaying(_ playing: Bool) {
        playing ? player?.play() : player?.pause()
    }

    func togglePlaying() {
        setPlaying(!isPlaying)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if !muted { ClipAudio.makeAudible() }
        player?.isMuted = muted
    }
}

/// What the phone does with its ring switch when a clip is asked to be heard.
///
/// The default session category silences any playback the moment the switch is flipped, which for
/// a clip somebody deliberately unmuted reads as the app being broken rather than as the phone
/// doing its job. Asking for the playback category is the one line that separates "this app makes
/// noise at me" from "this clip has sound in it".
@MainActor
enum ClipAudio {
    private static var configured = false

    static func makeAudible() {
        guard !configured else { return }
        configured = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

/// Playing a clip at the size of the phone rather than the size of a card. The system's own player
/// is what a video is expected to open into — scrubbing, AirPlay, Picture in Picture and the
/// full-screen gesture are all things it already has and none of them are worth rebuilding.
@MainActor
enum ClipTheatre {
    static func present(_ url: URL, from presenter: UIViewController) {
        ClipAudio.makeAudible()
        let controller = AVPlayerViewController()
        let player = AVPlayer(url: url)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        presenter.present(controller, animated: true) { player.play() }
    }
}
