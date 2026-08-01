import Foundation

/// Localized text for code that lives in this package rather than in an app target.
///
/// The string catalogue stays where it is — in each app's own resources — because `String
/// (localized:)` resolves against `Bundle.main` by default and a package's `.module` bundle would
/// silently fall back to the English key in every other language. `bundle:` is not an option
/// either: that overload does not exist on Linux, where `Bundle.localizedString` is the whole of
/// the API.
///
/// Arguments go through `String(format:)` rather than Swift interpolation, because a catalogue
/// entry may reorder them (`%2$@ … %1$@`) for a language whose word order differs.
public enum Localized {
    public static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil),
               arguments: arguments)
    }
}
