import CodingAgentKit
import TailscodeCore
import UIKit

extension ImageStudioViewController {
    func renderTapped() {
        guard !studio.isPainting else {
            Theme.Haptics.tap()
            studio.stop()
            return
        }
        let words = (promptView.text ?? "").trimmed()
        guard !words.isEmpty else { return }
        Theme.Haptics.send()
        view.endEditing(true)
        beforeEnhance = nil
        studio.submit(prompt: words)
    }

    /// Full size is the chat's own gallery, because a picture this app made deserves the same zoom,
    /// the same Live Text and the same ways out as one the agent handed over — paged over the
    /// whole shelf, fetched from the machine as each page is reached.
    func openStage() {
        guard let exhibit = studio.exhibit else { return }
        Theme.Haptics.tap()
        present(viewer(from: exhibit), animated: true)
    }

    private func viewer(from exhibit: ImageExhibit) -> ImageViewerViewController {
        let shelf = library
        let items = shelf.items
        let client = ImageGenClient(endpoint: studio.endpoint)
        if let target = exhibit.libraryID, let start = items.firstIndex(where: { $0.id == target }) {
            let pages = items.map { kept in
                GalleryImage(
                    id: kept.id,
                    file: FileReference(
                        path: kept.id, mime: kept.kind?.mime ?? "image/png",
                        url: client.viewURL(kept)?.absoluteString ?? "", filename: kept.filename),
                    localData: shelf.originalPath(of: kept).flatMap {
                        FileManager.default.contents(atPath: $0)
                    })
            }
            return ImageViewerViewController(
                items: pages, startIndex: start, backend: nil, from: nil
            ) { page in
                guard let kept = await shelf.item(named: page.id) else { return nil }
                return await shelf.original(of: kept)
            }
        }
        let pages = slot.pictures.map { made in
            GalleryImage(
                id: made.path,
                file: FileReference(
                    path: made.path, mime: "image/png", url: "file://" + made.path,
                    filename: ImageGenFacts.fileName(for: made)),
                localData: FileManager.default.contents(atPath: made.path))
        }
        let start = pages.firstIndex(where: { $0.id == exhibit.id }) ?? 0
        return ImageViewerViewController(items: pages, startIndex: start, backend: nil, from: nil)
    }

    func putOnStage(_ exhibit: ImageExhibit) {
        switch exhibit {
        case .made(let picture): studio.show(picture.path)
        case .kept(let item): studio.show(kept: item)
        }
    }

    func perform(_ action: ImageGenAction, on exhibit: ImageExhibit) {
        switch action {
        case .save:
            Task { [weak self] in
                guard let payload = await self?.studio.payload(of: exhibit) else { return }
                await self?.save(payload)
            }
        case .share:
            Task { [weak self] in
                guard let self, let payload = await self.studio.payload(of: exhibit) else { return }
                self.share(payload)
            }
        case .copy:
            Task { [weak self] in
                guard let self, let payload = await self.studio.payload(of: exhibit) else { return }
                ImageExport.copy(payload)
                Theme.Haptics.success()
                self.notice(ImageGenWords.copiedNotice)
            }
        case .open:
            Theme.Haptics.tap()
            present(viewer(from: exhibit), animated: true)
        case .again:
            Theme.Haptics.send()
            if exhibit != studio.exhibit { putOnStage(exhibit) }
            studio.again()
        case .stage:
            Theme.Haptics.selection()
            putOnStage(exhibit)
        case .reference:
            Theme.Haptics.selection()
            switch exhibit {
            case .made(let picture):
                studio.hold(ImageGenReference(path: picture.path, kept: picture.kept))
            case .kept(let item):
                studio.hold(kept: item)
            }
            if exhibit != studio.exhibit { putOnStage(exhibit) }
            promptView.becomeFirstResponder()
        case .discard:
            guard case .made(let picture) = exhibit else { return }
            Theme.Haptics.tap()
            studio.discard(picture.path)
            notice(ImageGenWords.discardNotice)
        }
    }

    /// The bridge to the other thing this app makes: the video forge opened over the work, holding
    /// this picture as the clip's first frame. A picture on the machine that renders the clip is
    /// named where it is so no byte travels; anywhere else the picture goes with the render.
    func animate(_ exhibit: ImageExhibit) {
        Theme.Haptics.tap()
        Task { [weak self] in
            guard let self, let start = await self.firstFrame(of: exhibit) else { return }
            ForgeRunner.shared.start(from: start.frame, width: start.width, height: start.height)
            let nav = UINavigationController(rootViewController: VideoForgeViewController())
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
    }

    private func firstFrame(of exhibit: ImageExhibit) async -> (frame: ForgeFrame, width: Int?, height: Int?)? {
        let sameMachine = ForgeRunner.shared.endpoint.map {
            ImageGenEndpoint(sharing: $0).displayHost == studio.endpoint.displayHost
        } ?? false
        switch exhibit {
        case .made(let picture):
            let size = studio.image(of: picture).map(Self.pixels(of:))
            if sameMachine, let remote = picture.remoteName {
                return (.kept(ImageGenLibraryItem(filename: remote).annotatedName), size?.0, size?.1)
            }
            return (.file(picture.path), size?.0, size?.1)
        case .kept(let item):
            let facts = library.facts(of: item)
            if sameMachine {
                return (.kept(item.annotatedName), facts?.width, facts?.height)
            }
            guard let payload = await studio.payload(of: item),
                let data = payload.data,
                let path = ImageGenFiles.stage(data, named: payload.filename)
            else {
                notice(ForgeFailure.unconfigured.description)
                return nil
            }
            let size = Self.pixels(of: payload.image)
            return (.file(path), size.0, size.1)
        }
    }

    static func pixels(of image: UIImage) -> (Int, Int) {
        (Int((image.size.width * image.scale).rounded()), Int((image.size.height * image.scale).rounded()))
    }

    /// Saving on a phone means the photo library, which is where a picture a person made goes —
    /// and it hands over the bytes the machine wrote rather than a re-encode of what is on screen.
    private func save(_ payload: ImagePayload) async {
        switch await ImageExport.saveToPhotos(payload) {
        case .saved:
            Theme.Haptics.success()
            notice(String(localized: "Saved to Photos"))
        case .denied:
            Theme.Haptics.warning()
            notice(String(localized: "Allow photo access in Settings to save pictures."))
        case .failed:
            Theme.Haptics.error()
            notice(String(localized: "Couldn't save to Photos"))
        }
    }

    private func share(_ payload: ImagePayload) {
        let item: Any = ImageExport.temporaryFile(payload) ?? payload.image
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    func presentSetup() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    /// What the machine can paint with, as the shared checklist for images and video led by pictures:
    /// the same one the video forge and the server screen open. Changing the machine goes through the
    /// renderer picker and returns to the checklist, and the studio follows the door.
    func presentMachine() {
        Theme.Haptics.tap()
        let held = studio
        MediaSetupGate.present(
            endpoint: studio.endpoint.forgeEndpoint, focus: .pictures, from: self,
            onChanged: { held.adoptDoor() })
    }

    func presentLibraryPicker() {
        let picker = ImageLibraryPickerViewController(library: library) { [weak self] item in
            self?.studio.hold(kept: item)
            self?.promptView.becomeFirstResponder()
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    func notice(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor)
    }
}
