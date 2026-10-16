import CodingAgentKit
import Foundation

/// Every word a client draws around a preview, written once. The host speaks in English and in
/// terms of its own steps; a person reads their own language and cares about the app, so each
/// fact the host reports is turned into a sentence here and no client invents one.
public enum PreviewReading {
    /// A Mac is ready when everything it needs is proven. Extras — instant updates, the screen
    /// inspector — are offered but never hold the preview back.
    public static func isReady(_ checks: [DoctorCheck]) -> Bool {
        let required = checks.filter { $0.optional != true }
        return !required.isEmpty && required.allSatisfy { $0.state == .ok }
    }

    public static func title(of check: DoctorCheck) -> String {
        switch check.id {
        case "silicon": return Localized.text("An Apple silicon Mac")
        case "xcode": return Localized.text("Xcode installed")
        case "firstLaunch": return Localized.text("Apple's license accepted")
        case "runtime": return Localized.text("An iPhone to run it on")
        case "streamer": return Localized.text("The screen streamer")
        case "disk": return Localized.text("Room to build")
        case "hotReload": return Localized.text("Instant updates")
        case "inspector": return Localized.text("Screen inspector")
        default: return check.title
        }
    }

    public static func detail(of check: DoctorCheck) -> String? {
        switch (check.id, check.state) {
        case ("xcode", .needsYou):
            return Localized.text(
                "Xcode is not on this Mac yet. It is free from the App Store: about 12 GB, around 40 minutes. You can leave; we will tell you when it is ready."
            )
        case ("firstLaunch", .needsYou):
            return Localized.text("Run this once in Terminal on the Mac: %@", "sudo xcodebuild -runFirstLaunch")
        case ("runtime", .fixable):
            return Localized.text("The iPhone simulator has to be downloaded once. It is a large download.")
        case ("streamer", .fixable):
            return Localized.text("A small tool that carries the picture. It will be fetched once.")
        case ("hotReload", .fixable):
            return Localized.text(
                "Edits to Swift code appear in the running app in under a second. A small library will be fetched once.")
        case ("inspector", .fixable):
            return Localized.text(
                "Lets you point at anything on the screen and check it for readability. It is built once on this Mac.")
        case ("disk", .needsYou):
            return Localized.text("Builds need about 8 GB free. Free some space on the Mac.")
        case ("silicon", .failed):
            return Localized.text("The screen streamer only runs on Apple silicon (M1 or later).")
        case (_, .working) where check.detail?.hasPrefix("Checked after") == true:
            return Localized.text("Checked after Xcode")
        default:
            return check.detail
        }
    }

    public static func fixLabel(_ fix: String) -> String {
        switch fix {
        case "showXcodeInAppStore": return Localized.text("Show it on my Mac")
        case "downloadIOSRuntime": return Localized.text("Download it")
        case "installStreamer": return Localized.text("Fetch it")
        case "installHotReload": return Localized.text("Turn it on")
        case "installInspector": return Localized.text("Build it")
        default: return Localized.text("Fix it")
        }
    }

    /// What the strip says while a session is coming up or changing, from the host's own step.
    public static func line(for session: SessionInfo) -> String? {
        if let step = session.step, let words = stepWords(step) { return words }
        switch session.state {
        case .preparing: return Localized.text("Getting ready")
        case .building: return Localized.text("Building your app")
        case .installing: return Localized.text("Installing")
        case .launching: return Localized.text("Opening your app")
        case .live: return nil
        case .failed: return session.step
        case .stopped: return Localized.text("Stopped")
        }
    }

    private static func stepWords(_ step: String) -> String? {
        switch step {
        case "Starting": return Localized.text("Starting")
        case "Finding your app": return Localized.text("Finding your app")
        case "Getting a simulator ready": return Localized.text("Getting a simulator ready")
        case "Building your app": return Localized.text("Building your app")
        case "Compiling": return Localized.text("Compiling")
        case "Linking": return Localized.text("Linking")
        case "Signing": return Localized.text("Signing")
        case "Packaging": return Localized.text("Packaging")
        case "Installing": return Localized.text("Installing")
        case "Opening your app": return Localized.text("Opening your app")
        case "Updating": return Localized.text("Updating")
        default: return nil
        }
    }

    public static func words(for path: ReloadPath) -> String {
        switch path {
        case .first: return Localized.text("Built")
        case .injected: return Localized.text("Updated in place")
        case .rebuilt: return Localized.text("Rebuilt and restarted")
        case .scratch: return Localized.text("Rebuilt from scratch")
        }
    }

    public static func summary(of report: BuildReport) -> String {
        Localized.text("%@ · %@ s", words(for: report.path), String(format: "%.1f", report.seconds))
    }

    /// The failure as a sentence a person can act on. What exactly went wrong sits under it, in
    /// `detailLine`, one tap away.
    public static func headline(of report: BuildReport) -> String {
        Localized.text("Your app stopped building after the last change.")
    }

    public static func detailLine(of issue: BuildIssue) -> String {
        guard let file = issue.file else { return issue.message }
        let name = (file as NSString).lastPathComponent
        guard let line = issue.line else { return "\(name): \(issue.message)" }
        return "\(name):\(line): \(issue.message)"
    }

    public static func firstError(of report: BuildReport) -> BuildIssue? {
        report.issues.first { $0.severity == .error }
    }

    public static func eventLine(_ event: SessionEvent) -> String? {
        switch event.kind {
        case "build.start": return Localized.text("Building…")
        case "build.done": return event.build.map { summary(of: $0) }
        case "build.failed": return event.build.map { headline(of: $0) }
        case "app.crashed": return Localized.text("The app closed on its own")
        case "app.recovered": return Localized.text("Opened it again on the same screen")
        case "app.loop": return Localized.text("The app keeps closing")
        case "stream.restart": return Localized.text("The picture stopped; bringing it back")
        case "stream.lost": return Localized.text("The picture stopped and would not come back")
        default: return nil
        }
    }

    public static func reachFailure(_ error: Error) -> String {
        switch error {
        case AgentError.http(let code, _) where code == 401 || code == 403:
            return Localized.text("The preview host wants its password")
        case AgentError.http(let code, _) where code == 404:
            return Localized.text("That address is not a preview host")
        default:
            return Localized.text("The Mac is not answering")
        }
    }
}
