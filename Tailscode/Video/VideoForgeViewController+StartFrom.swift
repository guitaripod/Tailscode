import TailscodeCore
import UIKit

extension VideoForgeViewController {
    var galleryIsHere: Bool {
        guard let endpoint = runner.endpoint else { return false }
        let library = ImageStudio.shared.library
        return !library.isEmpty
            && ImageGenEndpoint(sharing: endpoint).displayHost == library.endpoint.displayHost
    }

    func layoutStartFrom() {
        startFromRing.frame = startFrom.bounds
        startFromRing.path = UIBezierPath(
            roundedRect: startFrom.bounds.insetBy(dx: 1, dy: 1), cornerRadius: Theme.Radius.control
        ).cgPath
        startFromRing.strokeColor = Theme.Color.separator.cgColor
    }

    /// What the slot wears: the picture the clip opens on, the last frame of the clip it continues
    /// (its poster until that is read), or the invitation to choose one. One decision, three
    /// sources, and it says which.
    private func startFromThumbnail(_ frame: ForgeFrame) -> UIImage? {
        switch frame {
        case .file(let path):
            guard let data = FileManager.default.contents(atPath: path), let image = UIImage(data: data)
            else { return nil }
            return image.preparingThumbnail(of: CGSize(width: 120, height: 120)) ?? image
        case .kept(let name):
            let library = ImageStudio.shared.library
            return library.items.first(where: { $0.annotatedName == name })
                .flatMap { library.cachedThumbnail(of: $0) }
        case .clipEnd:
            guard let entry = board.continuing else { return nil }
            return picture(of: entry, endFrame: true)
        }
    }

    func updateStartFrom() {
        let frame = board.recipe.frame
        let thumb = frame.flatMap(startFromThumbnail)
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .fixed
        config.background.cornerRadius = Theme.Radius.control
        config.background.backgroundColor = Theme.Color.codeBackground
        config.imagePlacement = .top
        config.imagePadding = 2
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        if let thumb {
            config.background.image = thumb
            config.background.imageContentMode = .scaleAspectFill
        } else {
            let symbol = frame == nil ? "photo.badge.plus" : (frame?.isClipEnd == true ? "film" : "photo")
            config.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular))
            var caption = AttributedString(ForgeField.frame.label)
            caption.font = Theme.Font.capped(.caption2, maximum: 11)
            config.attributedTitle = caption
            config.baseForegroundColor = frame == nil
                ? Theme.Color.secondaryLabel : Theme.Color.accent
        }
        startFrom.configuration = config
        startFromRing.isHidden = frame != nil
        startFrom.isEnabled = !board.isBusy
        startFrom.titleLabel?.adjustsFontSizeToFitWidth = true
        startFrom.titleLabel?.minimumScaleFactor = 0.6
        startFrom.menu = startFromMenu()
        startFrom.accessibilityLabel = ForgeField.frame.label
        startFrom.accessibilityValue =
            frame.map { "\(board.continuing?.title ?? $0.label), \($0.detail)" } ?? ForgeWords.frameUnset
        startFrom.accessibilityHint = ForgeWords.frameHint
    }

    /// The doors a first frame can come through: the pictures on this device, the camera, a file,
    /// the clipboard, the machine's own gallery — and the end of a clip already made, which
    /// continues it. Letting go of the frame is one row.
    private func startFromMenu() -> UIMenu {
        var children: [UIMenuElement] = ImageChip.sourceActions(available: intake.available) {
            [weak self] source in self?.intake.present(source)
        }
        let clips = board.history.filter { board.canContinue($0) }.prefix(3).map { entry in
            UIAction(
                title: ForgeWords.continueTitle(entry), subtitle: ForgeWords.continueHint,
                image: UIImage(systemName: "film")
            ) { [weak self] _ in
                guard let asset = entry.asset else { return }
                Theme.Haptics.selection()
                self?.runner.start(from: .clipEnd(asset))
            }
        }
        if !clips.isEmpty {
            children.append(UIMenu(title: "", options: .displayInline, children: clips))
        }
        if board.recipe.frame != nil {
            children.append(
                UIAction(
                    title: ForgeWords.noFrameTitle, image: UIImage(systemName: "xmark.circle"),
                    attributes: .destructive
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    self?.runner.start(from: nil)
                })
        }
        return UIMenu(title: ForgeField.frame.label, children: children)
    }

    /// A picture handed in from the photo library, the camera, a file or the clipboard has no path
    /// of its own, so it is given one — the render puts it on the machine first.
    func startFromPicture(_ data: Data, named name: String) {
        guard let path = ImageGenFiles.stage(data, named: name) else { return }
        Theme.Haptics.selection()
        runner.start(from: .file(path))
    }

    func presentLibraryPicker() {
        let picker = ImageLibraryPickerViewController(library: ImageStudio.shared.library) {
            [weak self] item in
            Theme.Haptics.selection()
            let facts = ImageStudio.shared.library.facts(of: item)
            self?.runner.start(
                from: .kept(item.annotatedName), width: facts?.width, height: facts?.height)
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }
}
