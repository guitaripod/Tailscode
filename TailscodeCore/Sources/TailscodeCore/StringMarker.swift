import Foundation

extension String {
    /// Whether the text holds `marker`, found by a byte search over the string's own storage.
    ///
    /// Foundation's `contains` goes through `CFStringFind` with a locale and a UTF-16 copy of the
    /// text, which on a long answer costs more than the row built from it, and a chat that is
    /// opened asks it of every message it holds. A marker is ASCII, so the bytes are the whole
    /// question and a normalisation of the text could not change the answer.
    func holds(_ marker: StaticString) -> Bool {
        var text = self
        return text.withUTF8 { bytes in
            guard marker.utf8CodeUnitCount > 0 else { return true }
            guard let base = bytes.baseAddress else { return false }
            return memmem(base, bytes.count, marker.utf8Start, marker.utf8CodeUnitCount) != nil
        }
    }
}
