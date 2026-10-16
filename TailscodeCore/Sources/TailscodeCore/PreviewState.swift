import CodingAgentKit
import Foundation

public struct PreviewPicture: Sendable, Equatable {
    public var sequence: Int
    public var microseconds: UInt64
    public var jpeg: Data

    public init(sequence: Int, microseconds: UInt64, jpeg: Data) {
        self.sequence = sequence
        self.microseconds = microseconds
        self.jpeg = jpeg
    }
}

public enum PreviewPhase: Sendable, Equatable {
    case connecting
    case settingUp
    case starting
    case live
    case reconnecting
    case failed(String)
}

/// Everything a preview pane knows about its preview at one moment. The runner writes it from
/// whatever thread the news arrives on; a client reads the newest at its own frame and decides
/// only how to paint it.
public struct PreviewState: Sendable, Equatable {
    public var phase: PreviewPhase = .connecting
    public var checks: [DoctorCheck] = []
    public var fixes: [String: FixJob] = [:]
    public var session: SessionInfo?
    public var recent: [SessionEvent] = []
    public var hostVersion: String?
    public var needsPassword = false
    public var acceptsTouch = false

    public init() {}

    public var light: PreviewLight {
        switch phase {
        case .connecting, .starting: return .waking
        case .settingUp: return .needsYou
        case .live:
            if session?.step == "Updating" { return .updating }
            if session?.lastBuild?.ok == false { return .broken }
            return .live
        case .reconnecting: return .stale
        case .failed: return session == nil ? .offline : .broken
        }
    }

    public var lastBuild: BuildReport? { session?.lastBuild }

    public var frame: FrameInfo? { session?.frame }

    /// What the strip says under the app's name: where the preview is in coming up, or how the
    /// last change reached the picture.
    public var line: String {
        switch phase {
        case .connecting: return Localized.text("Finding the Mac")
        case .settingUp: return Localized.text("The Mac needs a few things")
        case .starting: return session.flatMap(PreviewReading.line(for:)) ?? Localized.text("Getting ready")
        case .reconnecting: return Localized.text("Finding the link again")
        case .failed(let reason): return reason
        case .live:
            if let session, let step = PreviewReading.line(for: session), session.step == "Updating" { return step }
            if let report = lastBuild {
                return report.ok ? PreviewReading.summary(of: report) : PreviewReading.headline(of: report)
            }
            return Localized.text("Live")
        }
    }

    /// The problem under a failed build, one line, for the card that explains it.
    public var firstProblem: String? {
        lastBuild.flatMap { PreviewReading.firstError(of: $0) }.map(PreviewReading.detailLine(of:))
    }

    public var isReadyToShow: Bool {
        if case .live = phase { return true }
        return false
    }
}
