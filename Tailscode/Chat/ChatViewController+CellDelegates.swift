import CodingAgentKit
import SafariServices
import UIKit

extension ChatViewController: PictureGalleryCellDelegate {
    func pictureGalleryCell(_ cell: PictureGalleryCell, didTapPictureAt index: Int) {
        let items = galleryImages()
        guard !items.isEmpty,
            let rowID = collectionView.indexPath(for: cell).flatMap({ dataSource.itemIdentifier(for: $0) })
        else { return }
        let start = items.firstIndex { $0.id == Self.pictureID(row: rowID, index: index) } ?? 0
        present(
            ImageViewerViewController(
                items: items, startIndex: start, backend: viewModel.backend, from: cell),
            animated: false)
    }
}

extension ChatViewController: ImageBubbleCellDelegate {
    func imageBubbleCell(_ cell: ImageBubbleCell, didTap image: UIImage, from view: UIView) {
        let items = galleryImages()
        let id = collectionView.indexPath(for: cell).flatMap { dataSource.itemIdentifier(for: $0) }
        let start = items.firstIndex { $0.id == id } ?? 0
        guard !items.isEmpty else { return }
        present(
            ImageViewerViewController(
                items: items, startIndex: start, backend: viewModel.backend, from: view),
            animated: false)
    }

    func imageBubbleCell(_ cell: ImageBubbleCell, menuFor payload: ImagePayload) -> UIMenu {
        imageMenu(for: payload, from: cell)
    }

    /// What a long-press on a picture offers, named for the file it is a picture of.
    fileprivate func imageMenu(for payload: ImagePayload, from source: UIView) -> UIMenu {
        UIMenu(
            title: payload.filename,
            children: [
                UIAction(
                    title: String(localized: "Save to Photos"),
                    image: UIImage(systemName: "square.and.arrow.down")
                ) { [weak self] _ in self?.saveToPhotos(payload) },
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    ImageExport.copy(payload)
                    Theme.Haptics.success()
                },
                UIAction(
                    title: String(localized: "Save to Files"),
                    image: UIImage(systemName: "folder")
                ) { [weak self] _ in self?.exportToFiles(payload, from: source) },
                UIAction(
                    title: String(localized: "Share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { [weak self] _ in self?.shareImage(payload, from: source) },
            ])
    }

    /// Every picture in the conversation, in the order it was said, so the
    /// viewer can swipe across the whole chat from whichever one was tapped. A strip contributes
    /// each of its pictures, named by the strip's row and the picture's place in it.
    fileprivate func galleryImages() -> [GalleryImage] {
        dataSource.snapshot().itemIdentifiers.flatMap { id -> [GalleryImage] in
            if case .image(let file)? = rowsByID[id]?.content {
                return [GalleryImage(id: id, file: file, localData: nil)]
            }
            if case .pictures(let files)? = rowsByID[id]?.content {
                return files.enumerated().map { index, file in
                    GalleryImage(id: Self.pictureID(row: id, index: index), file: file, localData: nil)
                }
            }
            guard id.hasPrefix("pending:"), id.contains(":img"),
                let echo = viewModel.pendingSends.first(where: {
                    id.hasPrefix("pending:\($0.id.uuidString):img")
                }),
                let index = Int(id.components(separatedBy: ":img").last ?? ""),
                echo.pictures.indices.contains(index)
            else { return [] }
            let attachment = echo.pictures[index]
            return [
                GalleryImage(
                    id: id,
                    file: FileReference(
                        path: nil, mime: attachment.mime,
                        url: "pending:\(echo.id.uuidString):\(index)",
                        filename: attachment.filename),
                    localData: attachment.data)
            ]
        }
    }

    fileprivate static func pictureID(row: String, index: Int) -> String { "\(row)#\(index)" }

    func saveToPhotos(_ payload: ImagePayload) {
        Task { [weak self] in
            switch await ImageExport.saveToPhotos(payload) {
            case .saved:
                Theme.Haptics.success()
                self?.presentToast(String(localized: "Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self?.presentToast(
                    String(localized: "Allow photo access in Settings to save pictures."))
            case .failed:
                Theme.Haptics.error()
                self?.presentToast(String(localized: "Couldn't save to Photos"))
            }
        }
    }

    private func exportToFiles(_ payload: ImagePayload, from source: UIView) {
        guard let url = ImageExport.temporaryFile(payload) else {
            presentToast(String(localized: "Couldn't export the picture."))
            return
        }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.popoverPresentationController?.sourceView = source
        picker.popoverPresentationController?.sourceRect = source.bounds
        present(picker, animated: true)
    }

    private func shareImage(_ payload: ImagePayload, from source: UIView) {
        let item: Any = ImageExport.temporaryFile(payload) ?? payload.image
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }
}

extension ChatViewController: TextBubbleCellDelegate {
    func textBubbleCell(_ cell: TextBubbleCell, didTapLink url: URL) {
        if let path = TextBubbleCell.path(fromActionURL: url) {
            presentPathActions(path, from: cell)
            return
        }
        openWebLink(url)
    }

    /// Every link here originates in model or tool output, and the markdown
    /// renderer preserves both an arbitrary label and an arbitrary scheme — so
    /// a transcript can present "docs" over `sms:`, `facetime:` or another
    /// app's deep link. Web links open in-app; anything else has to be
    /// confirmed against its real destination before it leaves the app.
    func openWebLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            present(SFSafariViewController(url: url), animated: true)
        default:
            confirmExternalOpen(url)
        }
    }

    private func confirmExternalOpen(_ url: URL) {
        let sheet = UIAlertController(
            title: String(localized: "Open outside Tailscode?"),
            message: url.absoluteString, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.addAction(
            UIAlertAction(title: String(localized: "Open"), style: .default) { _ in
                UIApplication.shared.open(url)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "Copy link"), style: .default) { [weak self] _ in
                UIPasteboard.general.string = url.absoluteString
                self?.presentToast(String(localized: "Link copied."))
            })
        present(sheet, animated: true)
    }

    private func presentPathActions(_ path: String, from source: UIView) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(title: path, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "Copy path"), style: .default) { [weak self] _ in
                UIPasteboard.general.string = path
                Theme.Haptics.success()
                self?.presentToast(String(localized: "Path copied."))
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "Add to message"), style: .default) {
                [weak self] _ in
                self?.composer.appendPath(path)
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }
}
