import CodingAgentKit
import Foundation

/// The ids `voice-bridge` reports and the facts each carries, written in the person's language. The
/// ids and facts are the gateway's own (its `Doctor`, see docs/setup.md): `name` on `voice.gpu`,
/// `totalMB` and `needMB` on `voice.vram`, `os` on `voice.docker`, `toolkit` on `voice.cdi`, `bytes`
/// and `needBytes` on `voice.model` and `voice.image`, `state`, `mode`, `progress`, `freeMB`, `needMB`
/// and `reason` on `voice.engine`, `version` on `voice.gateway`; a check waiting on another names it in
/// `after`, and a check whose job is running carries its id in `job`.
struct VoiceSetupReader: SetupCapabilityReader {
    let capability = SetupCapability.voice

    var name: String { Localized.text("Voice calls") }
    var setUpLabel: String { Localized.text("Set up voice") }
    var readyHeadline: String { Localized.text("Voice calls are ready") }
    var readyActionLabel: String { Localized.text("Try a call") }
    var beta: BetaFeature? { .voiceCall }
    var addTitle: String? { Localized.text("Add voice calls") }
    var addLine: String? { Localized.text("Talk to your chats out loud. Needs an NVIDIA GPU with 80 GB.") }

    func title(of check: SetupCheck) -> String? {
        switch check.id {
        case "voice.gpu": return Localized.text("Graphics card")
        case "voice.vram": return Localized.text("GPU memory")
        case "voice.docker": return Localized.text("Docker")
        case "voice.cdi": return Localized.text("GPU access in containers")
        case "voice.model": return Localized.text("Voice model")
        case "voice.image": return Localized.text("Voice engine image")
        case "voice.engine": return Localized.text("Voice engine")
        case "voice.gateway": return Localized.text("Voice service")
        default: return nil
        }
    }

    func line(of check: SetupCheck, locale: Locale) -> String? {
        let facts = SetupFacts(check.facts)
        if check.state == .unavailable && check.id != "voice.vram" && check.id != "voice.gpu" { return nil }
        switch check.id {
        case "voice.gpu": return gpuLine(check, facts)
        case "voice.vram": return vramLine(check, facts, locale)
        case "voice.docker": return dockerLine(check)
        case "voice.cdi":
            return check.state == .ok
                ? Localized.text("Containers can use the GPU")
                : Localized.text("Containers cannot use the GPU yet.")
        case "voice.model", "voice.image": return downloadLine(check, facts, locale)
        case "voice.engine": return engineLine(check, facts, locale)
        case "voice.gateway": return gatewayLine(check, facts, locale)
        default: return nil
        }
    }

    func impossibility(of check: SetupCheck, locale: Locale) -> String? {
        let facts = SetupFacts(check.facts)
        let need = SetupFormat.megabytes(VoiceRequirements.gpuMemoryMB, locale: locale)
        switch check.id {
        case "voice.gpu":
            return Localized.text("it has no NVIDIA GPU with %@", need)
        case "voice.vram":
            guard let total = facts.integer("totalMB") else { return nil }
            return Localized.text(
                "its GPU has %1$@ of memory and voice needs %2$@", SetupFormat.megabytes(total, locale: locale), need)
        default:
            return nil
        }
    }

    func fixLabel(of fix: SetupFix) -> String? {
        switch fix.id {
        case "voice.downloadModel": return Localized.text("Download the voice model")
        case "voice.pullImage": return Localized.text("Download the engine image")
        case "voice.installDocker": return Localized.text("Install Docker")
        case "voice.generateCDI": return Localized.text("Let containers use the GPU")
        case VoiceBridgeInstall.installFixID: return Localized.text("Install voice calls")
        default: return nil
        }
    }

    func fixReason(of fix: SetupFix) -> String? {
        switch fix.id {
        case "voice.installDocker":
            return Localized.text(
                "Installing Docker needs administrator rights, so this one is yours to run in a shell on the machine.")
        case "voice.generateCDI":
            return Localized.text(
                "Giving containers the GPU needs administrator rights, so this one is yours to run in a shell on the machine.")
        case VoiceBridgeInstall.installFixID:
            return Localized.text(
                "Run this in a shell on the machine. It downloads a ready-made program and needs no toolchain.")
        default:
            return nil
        }
    }

    func jobPhrase(of fixID: String) -> String? {
        switch fixID {
        case "voice.downloadModel": return Localized.text("downloading the voice model")
        case "voice.pullImage": return Localized.text("downloading the engine image")
        default: return nil
        }
    }

    private func gpuLine(_ check: SetupCheck, _ facts: SetupFacts) -> String {
        if check.state == .ok { return facts.text("name") ?? Localized.text("An NVIDIA GPU was found") }
        return Localized.text(
            "No NVIDIA GPU with %@ was found.", SetupFormat.megabytes(VoiceRequirements.gpuMemoryMB))
    }

    private func vramLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let total = facts.integer("totalMB").map { SetupFormat.megabytes($0, locale: locale) }
        if check.state == .ok {
            return total.map { Localized.text("%@ of GPU memory", $0) } ?? Localized.text("Enough memory is free")
        }
        let need = SetupFormat.megabytes(VoiceRequirements.gpuMemoryMB, locale: locale)
        guard let total else { return Localized.text("The card's memory size could not be read.") }
        return Localized.text("This GPU has %1$@ of memory and voice calls need a card with %2$@.", total, need)
    }

    private func dockerLine(_ check: SetupCheck) -> String {
        check.state == .ok
            ? Localized.text("Docker is installed")
            : Localized.text("Docker is not installed, or this account cannot use it. After the command, log out and back in so the docker group applies.")
    }

    private func downloadLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let have = facts.integer("bytes") ?? 0
        let total = facts.integer("needBytes")
        switch check.state {
        case .ok:
            return have > 0
                ? Localized.text("%@ on this machine", SetupFormat.bytes(have, locale: locale))
                : Localized.text("On this machine")
        case .working:
            return Localized.text("Downloading")
        default:
            if let total { return Localized.text("%@ to download", SetupFormat.bytes(max(0, total - have), locale: locale)) }
            return Localized.text("Not on this machine yet")
        }
    }

    private func engineLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        switch facts.text("state") {
        case "running": return Localized.text("Running")
        case "stopped": return Localized.text("Starts when you call and stops after ten idle minutes")
        case "loading":
            guard let progress = facts.number("progress") else {
                return Localized.text("Starting. This can take a few minutes.")
            }
            return Localized.text(
                "Starting, %@. This can take a few minutes.", SetupFormat.percent(progress, locale: locale))
        case "busy":
            let free = facts.integer("freeMB").map { SetupFormat.megabytes($0, locale: locale) }
            let need = SetupFormat.megabytes(facts.integer("needMB") ?? VoiceRequirements.engineMemoryMB, locale: locale)
            guard let free else { return Localized.text("The GPU is busy with another job") }
            return Localized.text(
                "Only %1$@ of the GPU is free and the voice model needs %2$@. Something else is using it, and voice calls never stop another job.",
                free, need)
        case "down":
            guard let reason = facts.text("reason") else { return Localized.text("Not running") }
            return Localized.text("Not running: %@", reason)
        default:
            return check.state == .working
                ? Localized.text("Starting. This can take a few minutes.") : Localized.text("Waits for the steps above")
        }
    }

    private func gatewayLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let version = facts.text("version")
        if check.state == .ok {
            return version.map { Localized.text("voice-bridge %@ is answering", $0) }
                ?? Localized.text("voice-bridge is answering")
        }
        if let version {
            return Localized.text("voice-bridge %@ is older than this app needs.", version)
        }
        return Localized.text(
            "voice-bridge is not installed on this machine yet. Voice calls need an NVIDIA GPU with %1$@ of memory and about %2$@ of downloads.",
            SetupFormat.megabytes(VoiceRequirements.gpuMemoryMB, locale: locale),
            SetupFormat.bytes(VoiceRequirements.modelBytes + VoiceRequirements.imageBytes, locale: locale))
    }
}
