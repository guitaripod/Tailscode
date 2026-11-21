import UIKit

/// A text view that is asked about a paste before UIKit takes it. Only a pasteboard holding a
/// picture is intercepted — words, and the overlong paste the delegate turns into a file, stay on
/// UIKit's own path so selection, undo and the system menu keep behaving exactly as they do
/// everywhere else on the phone.
final class PastingTextView: UITextView {
    var onPasteImage: ((Data, String) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, !pasteboard.hasStrings {
            if let png = pasteboard.image?.pngData() {
                onPasteImage?(png, "image/png")
                return
            }
        }
        super.paste(sender)
    }
}
