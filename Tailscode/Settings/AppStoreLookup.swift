import Foundation
import TailscodeCore

/// Apple's own record for this bundle identifier, read out of the storefront this device shops in.
///
/// The storefront is part of the answer rather than a detail of the request. Apple keeps a record
/// per country, the records do not agree, and a version quoted without naming the shop that
/// published it is a claim the reader cannot check — so the country code goes out with the query
/// and the shop's name comes back inside the release, where `AppRelease.fact` prints it.
///
/// An empty result is not a missing answer. It is Apple saying this app is not sold here, which is
/// a fact worth printing: the alternative is a surface that reads "not checked yet" forever on a
/// device whose store will never have a record to give it.
enum AppStoreLookup {
    static let bundleID = "com.guitaripod.tailscode"

    /// The record App Store Connect publishes this app under, kept in step with
    /// `scripts/asc-release.py`.
    static let appID = "6791660932"

    /// `itms-apps` opens the Store app itself, and an id resolves in whichever storefront the
    /// reader's account shops in — a country-scoped web address would send half the world to a
    /// page that does not sell this app.
    static let storeURL = "itms-apps://apps.apple.com/app/id\(appID)"

    /// Either a release or the sentence explaining why there is none. Both go straight into
    /// `UpdateReadings.app`, which is the only thing allowed to turn them into a verdict.
    enum Answer: Sendable {
        case release(AppRelease)
        case failure(String)
    }

    static func newest(now: Date = Date()) async -> Answer {
        let region = Locale.current.region?.identifier ?? "US"
        let shop = storefront(region)
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: region),
        ]
        guard let url = components?.url else {
            return .failure(String(localized: "The App Store address could not be built."))
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .failure(
                String(
                    localized:
                        "The App Store didn't answer, so nothing here can say what the newest version is."
                ))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .failure(
                String(
                    localized:
                        "The App Store answered \(http.statusCode) instead of a record for this app."
                ))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(String(localized: "The App Store's answer could not be read."))
        }
        let results = json["results"] as? [[String: Any]] ?? []
        let count = json["resultCount"] as? Int ?? results.count
        guard count > 0, let record = results.first else {
            return .failure(
                String(
                    localized:
                        "This app is not sold in the \(shop) store, so nothing here can say what the newest version is."
                ))
        }
        let version = (record["version"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty else {
            return .failure(
                String(
                    localized: "The \(shop) store's record for this app carries no version number."))
        }
        return .release(
            AppRelease(
                version: version, provenance: .appStore,
                notes: (record["releaseNotes"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                url: record["trackViewUrl"] as? String,
                publishedAt: (record["currentVersionReleaseDate"] as? String).flatMap(date(from:)),
                readAt: now, storefront: shop))
    }

    /// The shop's name in the reader's own language, falling back to its code — which is still
    /// better than an unnamed store, because the whole point of carrying it is that the reader can
    /// tell which record answered.
    private static func storefront(_ region: String) -> String {
        Locale.current.localizedString(forRegionCode: region) ?? region
    }

    /// Apple stamps the release date with internet date-time, sometimes with fractional seconds.
    /// A parser that only knows one of the two shapes silently loses the date, and every "released
    /// N days ago" downstream then reads as "nothing said when".
    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
