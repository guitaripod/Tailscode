import PhotosUI
import TailscodeCore
import UIKit
import UniformTypeIdentifiers

/// Every way a reference reaches the studio, from any screen that composes a picture.
///
/// The photo library, the camera, a file, the clipboard and the machine's own gallery are five
/// doors onto one gesture — hold this picture, the next render starts from it — so one object
/// owns the pickers and their delegates and the screen that presents it decides nothing but
/// where. Which doors are offered is read off the device: no camera on a simulator, no Paste
/// when the clipboard holds no picture, no gallery when the machine has none.
@MainActor
final class ImageReferenceIntake: NSObject {
    private weak var presenter: UIViewController?
    private let studio: ImageStudio
    private let onLibrary: () -> Void
    private var camera: UIImagePickerController?

    init(presenter: UIViewController, studio: ImageStudio, onLibrary: @escaping () -> Void) {
        self.presenter = presenter
        self.studio = studio
        self.onLibrary = onLibrary
    }

    var available: [ImageGenReferenceSource] {
        ImageGenReferenceSource.allCases.filter { source in
            switch source {
            case .photos, .files: return true
            case .camera: return UIImagePickerController.isSourceTypeAvailable(.camera)
            case .clipboard: return UIPasteboard.general.hasImages
            case .library: return !studio.library.isEmpty
            }
        }
    }

    /// The menu the reference chip opens: the sources when nothing is held; replace or remove when
    /// something is. Replacing is the same list one level down.
    func menu(holding reference: ImageGenReference?) -> UIMenu {
        let sources = ImageChip.sourceActions(available: available) { [weak self] source in
            self?.present(source)
        }
        guard reference != nil else { return UIMenu(title: ImageGenWords.attachTitle, children: sources) }
        return UIMenu(children: [
            UIMenu(
                title: ImageGenWords.replaceReference, image: UIImage(systemName: "photo.badge.arrow.down"),
                children: sources),
            UIAction(
                title: ImageGenWords.removeReference, image: UIImage(systemName: "xmark.circle"),
                attributes: .destructive
            ) { [weak self] _ in
                Theme.Haptics.tap()
                self?.studio.hold(nil)
            },
        ])
    }

    func present(_ source: ImageGenReferenceSource) {
        Theme.Haptics.tap()
        switch source {
        case .photos: presentPhotos()
        case .camera: presentCamera()
        case .files: presentFiles()
        case .clipboard: paste()
        case .library: onLibrary()
        }
    }

    private func presentPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        camera = picker
        presenter?.present(picker, animated: true)
    }

    private func presentFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presenter?.present(picker, animated: true)
    }

    private func paste() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() else { return }
        studio.hold(data: data, named: "pasted.png")
    }
}

extension ImageReferenceIntake: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let name = provider.suggestedName
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
            [weak self] data, _ in
            guard let data else { return }
            let kind = ImageBytes.kind(of: data)
            Task { @MainActor in
                self?.studio.hold(data: data, named: "\(name ?? "reference").\(kind.ext)")
            }
        }
    }
}

extension ImageReferenceIntake: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        camera = nil
        guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: 0.92)
        else { return }
        studio.hold(data: data, named: "photo.jpg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        camera = nil
    }
}

extension ImageReferenceIntake: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let data = FileManager.default.contents(atPath: url.path) else {
            return
        }
        studio.hold(data: data, named: url.lastPathComponent)
    }
}
