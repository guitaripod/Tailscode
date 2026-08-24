import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import TailscodeCore

/// The newest published release, read from the project's GitHub feed and remembered beside the
/// install.
///
/// A checkout reports on its own upstream and a storefront on its own record, but a package
/// install has neither: the package manager only answers the day it is asked. The one thing every
/// install shares is the release the tarball came from, so that is the comparison this desk gets
/// to make — fetched on the update cadence, never on a glance, and written down so a launch that
/// is not due still knows what the last check said.
enum LatestRelease {
    private static let projectURL = URL(
        string: "https://api.github.com/repos/guitaripod/Tailscode/releases/latest")!

    private static var cacheURL: URL {
        LinuxAppInstall.stateDirectory.appendingPathComponent("latest-release.json")
    }

    /// The answer for one reading. A fetch that is due consults the remote and remembers what came
    /// back; a launch that is not due reads the memory. A fetch that fails answers with the failure
    /// rather than with yesterday's memory, so "couldn't check" stays an honest sentence and the
    /// offer is only claimed by a check that actually made it.
    static func reading(fetching: Bool) async -> (release: AppRelease?, failure: String?) {
        guard fetching else { return (cached(), nil) }
        let fetched = await within(20) { await fetch() }
        if let fetched {
            remember(fetched)
            return (fetched, nil)
        }
        return (
            nil, Localized.text("Nothing came back from the project's releases.")
        )
    }

    private static func fetch() async -> AppRelease? {
        var request = URLRequest(url: projectURL)
        request.timeoutInterval = 20
        request.setValue(
            "Tailscode/\(TailscodeVersion.current)", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return GitHubRelease.parse(data)
    }

    /// The last fetched release, or nothing on a machine that never fetched one.
    private static func cached() -> AppRelease? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(AppRelease.self, from: data)
    }

    private static func remember(_ release: AppRelease) {
        guard let data = try? JSONEncoder().encode(release) else { return }
        try? FileManager.default.createDirectory(
            at: LinuxAppInstall.stateDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Nothing here may wait forever. The feed is a single round trip, and a machine that has
    /// stopped answering it at all is not a machine that answered "no release".
    private static func within<T: Sendable>(
        _ seconds: Int, _ work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
