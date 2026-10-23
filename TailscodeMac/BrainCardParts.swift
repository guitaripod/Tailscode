import AppKit
import TailscodeCore

/// The collapsed turn: a card whose picture is the head lit where the turn worked and whose words
/// are what the turn came to, drawn in one view.
///
/// Everything but the picture is drawn here, in one pass over a handful of strings, because a
/// conversation of three hundred turns must cost the few cards in view and not three hundred
/// stacks of labels; AppKit asks a view for its pixels only while it is on screen. The picture is a
/// layer tree of the row's (it is the one thing that travels when the card opens), the tone edge is
/// a layer of its own so the render server can pulse it, and the pointer's two small buttons and
/// zone chips are rectangles this view hit-tests itself.
///
/// A running turn's card keeps the settled card's size and says what is happening in the reader's
/// words: the verdict, the counts, and a NOW line. When the turn ends the card settles in one 400 ms
/// move that Core times (`NeuralCardSettle`); the view only reads it.
/// The pictures of cards at rest: the few that were drawn last, so that a page asking every card
/// to draw again finds them done. A picture is a card's width by its height at the screen's
/// scale, a megabyte or two, so what is held is bounded in bytes, and let go of when the app has
/// been away.
@MainActor
final class BrainCardPictures {
    static let shared = BrainCardPictures()
    static let budget = 48 * 1_048_576

    private var bytes = 0

    private var held: [ObjectIdentifier: (key: Int, image: CGImage)] = [:]
    private var order: [ObjectIdentifier] = []

    func picture(for id: ObjectIdentifier, key: Int) -> CGImage? {
        guard let entry = held[id], entry.key == key else { return nil }
        touch(id)
        return entry.image
    }

    func keep(_ image: CGImage, for id: ObjectIdentifier, key: Int) {
        if let old = held[id] { bytes -= Self.size(of: old.image) }
        held[id] = (key, image)
        bytes += Self.size(of: image)
        touch(id)
        while bytes > Self.budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let gone = held.removeValue(forKey: oldest) { bytes -= Self.size(of: gone.image) }
        }
    }

    func forget(_ id: ObjectIdentifier) {
        if let gone = held.removeValue(forKey: id) { bytes -= Self.size(of: gone.image) }
        order.removeAll { $0 == id }
    }

    func dropAll() {
        held = [:]
        order = []
        bytes = 0
    }

    private static func size(of image: CGImage) -> Int { image.bytesPerRow * image.height }

    var count: Int { held.count }

    private func touch(_ id: ObjectIdentifier) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

/// The one second a live card ticks at while any of them is on screen: the counts and the silence
/// move without anything arriving. Settled cards register nothing, so a conversation of finished
/// turns owns no timer; the timer runs only while some live card is in a window somebody can see
/// (`DisplayGate`) and stops the moment none is, to start again when the app, a window or a scroll
/// brings one back.
@MainActor
final class BrainLiveTick {
    static let shared = BrainLiveTick()
    private let cards = NSHashTable<BrainCardView>.weakObjects()
    private var timer: Timer?
    private var observing = false

    var isRunning: Bool { timer != nil }
    var cardCount: Int { cards.allObjects.count }

    func register(_ card: BrainCardView) {
        cards.add(card)
        observe()
        reconsider()
    }

    func unregister(_ card: BrainCardView) {
        cards.remove(card)
        reconsider()
    }

    /// Starts the timer when a registered card can be seen, and stops it when none can.
    func reconsider() {
        let seen = cards.allObjects.contains { $0.isSeen }
        if seen, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainThread.call { self?.tick() }
            }
            timer?.tolerance = 0.1
        } else if !seen, timer != nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func observe() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSView.boundsDidChangeNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainThread.call { self?.reconsider() }
            }
        }
    }

    private func tick() {
        let live = cards.allObjects
        guard live.contains(where: { $0.isSeen }) else {
            reconsider()
            return
        }
        for card in live { card.liveSecondPassed() }
    }
}
