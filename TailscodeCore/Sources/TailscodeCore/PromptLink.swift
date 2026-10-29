import Foundation

/// The words a `tailscode://compose?text=` or `tailscode://ask?text=` link carries, so a prompt
/// written somewhere else — a Quicklink on a third-party keyboard, a Shortcut, a script — arrives in
/// the box already written instead of waiting to be typed again.
///
/// Anything on the device can open a `tailscode://` URL, so the words are only ever a draft: a client
/// puts them in the box, shows them, and leaves sending to the person. A link never sends, and the
/// words are never logged.
public enum PromptLink {
    public static let textKey = "text"

    public static func text(in url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == textKey })?.value else { return nil }
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }
}
