import Foundation
import TailscodeCore

/// What this copy of the app is, read off the bundle it is running out of.
///
/// The marketing version and the build number are kept apart on purpose: `1.9 (30)` parses as
/// nothing, so folding them into one string would make every comparison against the store
/// unavailable and the whole surface would answer "can't compare" forever. The stamp a bug report
/// wants is assembled by `AppInstall.stamp`; the number a comparison wants is the marketing
/// version alone.
enum AppInstallProbe {
    static func current() -> AppInstall {
        AppInstall(
            kind: kind, version: info("CFBundleShortVersionString"), build: info("CFBundleVersion"),
            provenance: .appBundle, installedAt: installedAt())
    }

    /// How this copy got here, which is the whole of what it may honestly offer to do about a
    /// newer one. The simulator is decided first because it is decided at compile time: a
    /// simulator's receipt is also named `sandboxReceipt`, so asking the receipt first would
    /// report every simulator run as a TestFlight build.
    private static var kind: AppInstall.Kind {
        #if targetEnvironment(simulator)
            return .simulator
        #else
            return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
                ? .testFlight : .appStore
        #endif
    }

    /// When the bundle was laid down, which on iOS is when this build was installed. Absent rather
    /// than guessed when the attribute cannot be read.
    private static func installedAt() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: Bundle.main.bundlePath)
        return attributes?[.creationDate] as? Date
    }

    private static func info(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}
