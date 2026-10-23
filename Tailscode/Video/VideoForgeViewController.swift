import TailscodeCore
import UIKit

/// Asking for a video, and watching it be made.
///
/// The screen has the same anatomy as the image studio's, because it is the same machine making
/// the other thing: the stage owns the screen — the machine's own sketch of the clip while it
/// renders, the clip playing in the rectangle the sketch used when it lands — with the verbs that
/// get a clip out under it, the shelf of clips already made under those, and at the foot the brief
/// written like a sentence: what to start from, the words, how, go.
///
/// Everything on it is `ForgeBoard`'s and `ForgeJob`'s: every word, which settings walk, what the
/// button says it would do, how far each pass is. The controller draws them and does the things a
/// board cannot — open a text box, put a clip on screen, hand a picture to the render.
///
/// The render itself is `ForgeRunner`'s, not this screen's: a clip is minutes of another machine's
/// card, and a phone goes in a pocket halfway through. Backing out and coming back finds the same
/// render exactly where it was.
@MainActor
final class VideoForgeViewController: UIViewController {
    enum StripItem: Hashable {
        case job
        case clip(String)
        case note
    }

    let runner = ForgeRunner.shared
    let stage = StudioStageView()
    let player = ClipPlayerView()
    let verbs = StudioVerbsBar()
    var strip: UICollectionView!
    var stripSource: UICollectionViewDiffableDataSource<Int, StripItem>!
    let pill = StudioMachinePill()
    lazy var menuItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu())

    let dock = Theme.Glass.view()
    let chipFlow = StudioChipFlow()
    let promptView = StudioPromptView()
    let placeholder = UILabel()
    let clearButton = UIButton(type: .system)
    let startFrom = UIButton(type: .system)
    let startFromRing = CAShapeLayer()
    let enhanceControl = StudioEnhanceControl()
    let renderButton = UIButton(type: .system)
    var promptHeight: NSLayoutConstraint!
    var growing = false
    var appliedChips: String?
    var beforeEnhance: String?
    let enhancement = PromptEnhancementController()
    weak var enhanceOverlay: PromptEnhanceOverlay?
    var intake: ImageReferenceIntake!

    var stageEntry: ForgeEntry?
    var stageClip: (asset: ForgeAsset, url: URL)?
    var stageFailure: String?
    var locating: Task<Void, Never>?
    /// Bumped by everything that decides what the stage is on. An answer to an earlier question —
    /// the renderer confirming a file two taps ago — arrives after the person has moved on, and is
    /// only believed while its number is still the latest.
    var stageTicket = 0
    var peeking: Task<Void, Never>?
    var sharing = false
    var seedReused = false
    var framesAsked: Set<String> = []
    var stripStamp: String?
    var revealed: String?
    var muted = true
    var sketchFrame: ImageGenPreviewFrame?
    var sketchImage: UIImage?
    var decoding: Task<Void, Never>?
    var clock: Task<Void, Never>?
    var wasRendering = false

    var board: ForgeBoard { runner.board }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ForgeSurface.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ForgeSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = menuItem
        navigationItem.titleView = pill
        menuItem.accessibilityLabel = ImageGenWords.moreTitle
        pill.addAction(UIAction { [weak self] _ in self?.openChecklist() }, for: .touchUpInside)
        intake = ImageReferenceIntake(
            presenter: self,
            deliver: { [weak self] data, name in self?.startFromPicture(data, named: name) },
            hasGallery: { [weak self] in self?.galleryIsHere ?? false },
            onLibrary: { [weak self] in self?.presentLibraryPicker() })
        configureStage()
        configureStrip()
        configureDock()
        configureStripSource()
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange), name: ForgeRunner.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange), name: ImageStudio.didChange, object: nil)
        wasRendering = runner.isRendering
        setPrompt(board.recipe.prompt)
        render(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grow()
        layoutStartFrom()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !runner.isRendering else { return }
        runner.prepare()
        ImageStudio.shared.library.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        acknowledgeFailureIfShown()
        #if DEBUG
            scrollForVerification()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runner.rememberRecipe()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            appliedChips = nil
            updateChips()
            updateVerbs()
            updateRenderButton()
        }
    }
}
