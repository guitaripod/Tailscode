import Foundation

/// The newest published release, read from the project's own release feed.
///
/// A store client learns what is new from its storefront and a checkout build from its upstream,
/// but a package-installed desktop has neither: its package manager only answers the day it is
/// asked, and the binary itself has nothing to compare against. The one thing every install
/// shares is the GitHub release the tarball came from, so that is where the "is there a newer
/// one" question is put.
public enum GitHubRelease {
    private struct Payload: Decodable {
        let tagName: String?
        let body: String?
        let htmlURL: String?
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
        }
    }

    /// The release a person or a workflow actually published, or nothing at all.
    ///
    /// Every field the surface later renders is optional on the wire — a release made by hand can
    /// lack a body or a URL — so nothing is required except the tag the version is read from. A
    /// response that cannot be read as a release at all answers nil, which the reading turns into
    /// "could not say" rather than into a claim about the newest version.
    public static func parse(_ data: Data, now: Date = Date()) -> AppRelease? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return nil }
        guard let tag = payload.tagName else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        return AppRelease(
            version: version, provenance: .gitHubRelease,
            notes: payload.body, url: payload.htmlURL,
            publishedAt: payload.publishedAt, readAt: now)
    }
}
