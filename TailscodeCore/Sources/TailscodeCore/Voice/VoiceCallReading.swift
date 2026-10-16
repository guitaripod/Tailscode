import CodingAgentKit
import Foundation

/// Every word a call says that is not the beta card's. A client draws these and spells nothing.
public enum VoiceCallReading {
    public static var name: String { Localized.text("Call") }

    public static var start: String { Localized.text("Start call") }
    public static var hangUp: String { Localized.text("Hang up") }
    public static var mute: String { Localized.text("Mute") }
    public static var unmute: String { Localized.text("Unmute") }
    public static var muteTooltip: String { Localized.text("Mute the microphone") }
    public static var unmuteTooltip: String { Localized.text("Unmute the microphone") }
    public static var mutedNote: String { Localized.text("Microphone muted") }
    public static var youLabel: String { Localized.text("You") }
    public static var youPlaceholder: String { Localized.text("What you say shows here as it is heard") }
    public static var agentFinished: String { Localized.text("The agent finished") }
    public static var reconnecting: String { Localized.text("Reconnecting the call…") }
    public static var sentNote: String { Localized.text("Sent to the agent") }

    static var timedOut: String { Localized.text("it did not answer in time") }
    static var machineUnreachable: String { Localized.text("the machine could not be reached") }

    static func httpStatus(_ status: Int) -> String { Localized.text("it answered with status %@", "\(status)") }

    public static func word(for face: VoiceCallFace) -> String {
        switch face {
        case .connecting: return Localized.text("Connecting")
        case .listening: return Localized.text("Listening")
        case .hearing: return Localized.text("Hearing you")
        case .speaking: return Localized.text("Speaking")
        case .working: return Localized.text("Agent working")
        case .degraded: return Localized.text("Voice paused")
        case .ended: return Localized.text("Call ended")
        }
    }

    public static var startingTheModel: String { Localized.text("Starting the voice model") }

    public static func startingTheModel(progress: Double?) -> String {
        guard let progress else { return startingTheModel }
        return Localized.text("Starting the voice model, %@", SetupFormat.percent(progress))
    }

    public static var startingTheModelSpoken: String {
        Localized.text("Starting the voice model. This can take a few minutes.")
    }

    public static func spoken(for face: VoiceCallFace) -> String {
        switch face {
        case .connecting: return Localized.text("Connecting the call")
        case .listening: return Localized.text("Listening. Go ahead and speak")
        case .hearing: return Localized.text("Hearing you")
        case .speaking: return Localized.text("The voice is speaking")
        case .working: return Localized.text("Listening. The agent is working")
        case .degraded(let reason): return Localized.text("The voice is paused. %@", degraded(reason))
        case .ended: return Localized.text("The call has ended")
        }
    }

    public static func degraded(_ reason: VoiceDegradedReason, recovering: Bool = false) -> String {
        let line: String
        switch reason {
        case .runaway: line = Localized.text("The voice would not stop talking, so it was stopped.")
        case .loop: line = Localized.text("The voice began repeating itself, so it was stopped.")
        case .engineError: line = Localized.text("The voice model hit an error.")
        case .engineDown: line = Localized.text("The voice model stopped running on the server.")
        case .overload: line = Localized.text("The server is too busy for the voice right now.")
        }
        return recovering ? Localized.text("%@ Starting it fresh.", line) : line
    }

    public static func reason(for reach: VoiceReach) -> String {
        switch reach {
        case .unknown:
            return Localized.text("Calling has not been checked on this server yet")
        case .checking:
            return Localized.text("Checking the voice gateway…")
        case .ready(let gateway):
            return Localized.text("Ready to call: voice-bridge %@ is answering", gateway)
        case .stopped:
            return Localized.text("The voice model starts when you call, which can take a few minutes.")
        case .needsSetup:
            return Localized.text("Voice calls need a one-time setup on this server. Press Call to see what is left.")
        case .loading:
            return Localized.text(
                "The voice model is still loading on the server, which can take a few minutes. Try again shortly.")
        case .busy:
            return Localized.text("The server's GPU is busy with another call. Try again when it ends.")
        case .noGateway:
            return Localized.text(
                "Voice calls are not set up on this server yet. Press Call and the checklist shows where to start.")
        case .tooOld(let version):
            return version < VoiceWire.version
                ? Localized.text("voice-bridge on this server is older than this app. Update it there.")
                : Localized.text("voice-bridge on this server is newer than this app. Update Tailscode.")
        case .engineDown(let detail):
            guard let detail, !detail.isEmpty else {
                return Localized.text("The voice model is not running on the server. Press Call to see why and how to start it.")
            }
            return Localized.text("The voice model is not running on the server (%@). Press Call to see how to start it.", detail)
        case .wantsPassword:
            return Localized.text("The voice gateway asks for a password. Add it for this server.")
        case .unreachable(let why):
            return Localized.text("The voice gateway could not be reached: %@", why)
        }
    }

    public static func buttonLabel(active: Bool) -> String { active ? hangUp : name }

    public static func tooltip(reach: VoiceReach, active: Bool) -> String {
        if active { return Localized.text("Hang up the call") }
        if reach.canStart { return Localized.text("Speak to this chat and it types what you say") }
        return reach.line
    }

    public static func accessibility(reach: VoiceReach, active: Bool) -> String {
        if active { return Localized.text("Hang up the call") }
        if reach.canStart { return Localized.text("Call this chat. It types what you say") }
        return Localized.text("Call, unavailable. %@", reach.line)
    }

    public static func microphoneDenied(client: VoiceClientKind) -> String {
        switch client {
        case .ios:
            return Localized.text(
                "Tailscode cannot hear you. Turn on Microphone for Tailscode in Settings, under Privacy & Security, then call again.")
        case .mac:
            return Localized.text(
                "Tailscode cannot hear you. Turn on Tailscode in System Settings, under Privacy & Security, Microphone, then call again.")
        case .linux:
            return Localized.text(
                "Tailscode cannot hear you. Pick an input device in your sound settings, then call again.")
        }
    }

    public static func end(_ end: VoiceCallEnd, client: VoiceClientKind) -> String {
        switch end {
        case .hungUp:
            return Localized.text("Call ended")
        case .replaced:
            return Localized.text("Another call was started, so this one ended.")
        case .lost:
            return Localized.text(
                "The connection to the voice gateway was lost and could not be restored. Check the tailnet and call again.")
        case .couldNotConnect(let why):
            return Localized.text("The call could not connect: %@", why)
        case .microphoneDenied:
            return microphoneDenied(client: client)
        case .audioUnavailable(let why):
            return Localized.text("The audio could not start: %@", why)
        case .gateway(let code, let message):
            return gatewayEnd(code: code, message: message)
        }
    }

    private static func gatewayEnd(code: String, message: String) -> String {
        switch code {
        case "busy":
            return Localized.text("Another call is already using the voice model. Try again when it ends.")
        case "version":
            return Localized.text("This app and voice-bridge speak different versions. Update the older one.")
        case "engineDown":
            return degraded(.engineDown)
        case "silent":
            return Localized.text("The gateway stopped hearing from this device and ended the call.")
        case "hello":
            return Localized.text("The gateway did not understand this app. Update voice-bridge and try again.")
        default:
            guard !message.isEmpty else { return Localized.text("The gateway ended the call.") }
            return Localized.text("The gateway ended the call: %@", message)
        }
    }
}
