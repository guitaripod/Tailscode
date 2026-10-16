import Foundation
import TailscodeCore

/// What a beta report says about the build and the Mac it ran on, read the way the update surface
/// reads them so the seen-store and the report agree on which version this is.
enum BetaEnvironment {
    static let appVersion: SoftwareVersion =
        MacAppInstall.version.flatMap(SoftwareVersion.init) ?? SoftwareVersion("0")!

    static var appLine: String {
        let version = MacAppInstall.version ?? appVersion.raw
        let build = MacAppInstall.build.map { ", build \($0)" } ?? ""
        return "Tailscode \(version) (\(channel)\(build))"
    }

    static var systemLine: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersion.versionString) · \(hardware)"
    }

    /// Which of the two Mac builds this is, because a report from the sandboxed copy and one from
    /// the copy somebody installed themselves are not the same evidence.
    private static var channel: String {
        #if TAILSCODE_MAS
            return "App Store"
        #else
            return "direct"
        #endif
    }

    private static var hardware: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private extension OperatingSystemVersion {
    var versionString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
