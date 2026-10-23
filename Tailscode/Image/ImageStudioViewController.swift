import TailscodeCore
import UIKit

/// Asking for a picture, and everything that happens to it afterwards.
///
/// The stage is the room and it owns the screen: the picture, or the machine's own sketch of it
/// while it is painted, at the size the render will land in, with the verbs that get it out — into
/// Photos, to another app, onto the pasteboard, rolled again, used as the reference the next
/// render starts from, or animated into a clip — directly under it. Under the verbs is the shelf:
/// every picture the machine keeps, whoever made it, newest first, the render in flight leading
/// it, with the one on the stage ringed. At the foot is the brief, written like a sentence: what
/// to start from, the words, how, go.
///
/// The render itself is `ImageStudio`'s, not this screen's: backing out closes a screen, and
/// coming back finds the same picture exactly where it was.
@MainActor
final class ImageStudioViewController: UIViewController {
    enum StripItem: Hashable {
        case job
        case tile(String)
        case note
    }

    let studio = ImageStudio.shared
    let stage = StudioStageView()
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
    var wasPainting = false
    var loadingOriginal: String?
    var shownExhibitID: String?
    var clock: Task<Void, Never>?
    var referenceRatios: [String: CGFloat] = [:]

    var slot: ImageGenSlot { studio.slot }
    var library: ImageLibrary { studio.library }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ImageGenSurface.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ImageGenSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = menuItem
        navigationItem.titleView = pill
        menuItem.accessibilityLabel = ImageGenWords.moreTitle
        pill.addAction(UIAction { [weak self] _ in self?.presentMachine() }, for: .touchUpInside)
        intake = ImageReferenceIntake(presenter: self, studio: studio) { [weak self] in
            self?.presentLibraryPicker()
        }
        configureStage()
        configureStrip()
        configureDock()
        configureStripSource()
        for name in [ImageStudio.didChange, ImageGenStore.didChange, ForgeStore.didChange] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(studioDidChange), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(progressDidChange), name: ImageStudio.progressDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange), name: ImageLibrary.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(itemDidChange(_:)), name: ImageLibrary.itemDidChange,
            object: nil)
        wasPainting = studio.isPainting
        setPrompt(slot.promptDraft)
        render(animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        grow()
        layoutStartFrom()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        studio.adoptDoor()
        studio.checkMachine()
        library.refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["TAILSCODE_IMAGE_MACHINE"] != nil, presentedViewController == nil {
                presentMachine()
            }
            if environment["TAILSCODE_IMAGE_FOCUS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.promptView.becomeFirstResponder()
                }
            }
            if environment["TAILSCODE_IMAGE_SCROLL"] == "library" {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard let self, let last = self.library.items.last,
                        let path = self.stripSource.indexPath(for: .tile(last.id))
                    else { return }
                    self.strip.scrollToItem(at: path, at: .right, animated: true)
                }
            }
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        studio.rememberDraft(promptView.text ?? "")
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
