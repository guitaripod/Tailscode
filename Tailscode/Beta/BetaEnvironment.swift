import Foundation
import TailscodeCore

/// What a beta report says about the build and the phone it ran on, read the way the update surface
/// reads them so the seen-store and the report agree on which version this is.
enum BetaEnvironment {
    static let appVersion: SoftwareVersion =
        AppInstallProbe.current().version.flatMap(SoftwareVersion.init) ?? SoftwareVersion("0")!

    static let appLine = "Tailscode \(AppInstallProbe.current().stamp ?? appVersion.raw)"

    static var systemLine: String {
        "iOS \(ProcessInfo.processInfo.operatingSystemVersion.versionString) · \(hardware)"
    }

    private static var hardware: String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafeBytes(of: machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

private extension OperatingSystemVersion {
    var versionString: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
