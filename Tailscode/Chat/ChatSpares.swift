import TailscodeCore
import UIKit

/// The parts of a chat's screen that are the same for every chat, made ahead of the press that
/// needs them.
///
/// A composer is a text view, a glass bar and a microphone; with the model pill and the chips of
/// the facts row it is most of what making a chat's screen costs on an older phone, and that cost
/// sat between the press on a row and the first frame of the push. So one set is kept made while
/// nobody is waiting on it, a part to a turn of the run loop so that making it never holds a frame.
/// A part handed out has never been in a window, shown a word or had a target, so it is exactly a
/// new one, and it takes the colours and type of the window it joins the way any view does. A
/// press that finds no spare makes the part on the spot, as before.
@MainActor
enum ChatSpares {
    private static var composer: ComposerView?
    private static var pill: ModelDialPill?
    private static var palette: SlashCommandPalette?
    private static var banner: BannerView?
    private static var placeholder: WorkingPlaceholderView?
    private static var chips: [ChatChrome.Kind: [ChatChip]] = [:]
    private static var preparing = false

    /// How many chips of each kind one chat's facts row holds.
    private static let chipsPerChat: [(kind: ChatChrome.Kind, count: Int)] = [
        (.live, 3), (.fact, 6), (.control, 1),
    ]

    static func takeComposer() -> ComposerView {
        defer { composer = nil }
        return composer ?? ComposerView()
    }

    static func takePill() -> ModelDialPill {
        defer { pill = nil }
        return pill ?? ModelDialPill()
    }

    static func takePalette() -> SlashCommandPalette {
        defer { palette = nil }
        return palette ?? SlashCommandPalette()
    }

    static func takeBanner() -> BannerView {
        defer { banner = nil }
        return banner ?? BannerView()
    }

    static func takePlaceholder() -> WorkingPlaceholderView {
        defer { placeholder = nil }
        return placeholder ?? WorkingPlaceholderView()
    }

    static func takeChip(_ kind: ChatChrome.Kind) -> ChatChip {
        chips[kind]?.popLast() ?? ChatChip(kind: kind)
    }

    /// Makes whatever is missing a moment from now, once the screen that asked has settled, and
    /// only while the app is in front: nothing is built for a press that cannot come.
    static func prepare() {
        _ = watch
        guard !preparing else { return }
        preparing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(900)) {
            MainActor.assumeIsolated { makeNext() }
        }
    }

    /// A part is made at the type size in force, and held for nobody under memory pressure: a
    /// change of size or a warning drops the set, and the next screen to settle makes another.
    private static let watch: Void = {
        for name in [
            UIContentSizeCategory.didChangeNotification,
            UIApplication.didReceiveMemoryWarningNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { drop() }
            }
        }
    }()

    private static func drop() {
        composer = nil
        pill = nil
        palette = nil
        banner = nil
        placeholder = nil
        chips = [:]
    }

    private static func makeNext() {
        guard UIApplication.shared.applicationState == .active, makeOnePart() else {
            preparing = false
            return
        }
        RunLoopTurn.next { makeNext() }
    }

    /// Makes the first part found missing and says whether there was one.
    private static func makeOnePart() -> Bool {
        if composer == nil {
            composer = ComposerView()
        } else if pill == nil {
            pill = ModelDialPill()
        } else if palette == nil {
            palette = SlashCommandPalette()
        } else if banner == nil {
            banner = BannerView()
        } else if placeholder == nil {
            placeholder = WorkingPlaceholderView()
        } else if let short = chipsPerChat.first(where: { (chips[$0.kind]?.count ?? 0) < $0.count }) {
            chips[short.kind, default: []].append(ChatChip(kind: short.kind))
        } else {
            return false
        }
        return true
    }
}
