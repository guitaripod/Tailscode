import CodingAgentKit
import Foundation

/// The ids `voice-bridge` reports and the facts each carries, written in the person's language. The
/// facts are the contract with the gateway (see docs/setup.md): `name` and `vramMB` on `voice.gpu`,
/// `freeMB` and `needMB` on `voice.vram`, `bytes` on `voice.model` and `voice.image`, `version` on
/// `voice.docker` and `voice.gateway`, `engine` on `voice.engine`.
struct VoiceSetupReader: SetupCapabilityReader {
    let capability = SetupCapability.voice

    var name: String { Localized.text("Voice calls") }
    var setUpLabel: String { Localized.text("Set up voice") }
    var readyHeadline: String { Localized.text("Voice calls are ready") }
    var readyActionLabel: String { Localized.text("Try a call") }
    var beta: BetaFeature? { .voiceCall }

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
        switch check.id {
        case "voice.gpu": return gpuLine(check, facts, locale)
        case "voice.vram": return vramLine(check, facts, locale)
        case "voice.docker": return dockerLine(check, facts)
        case "voice.cdi":
            return check.state == .ok
                ? Localized.text("Containers can use the GPU")
                : Localized.text("Containers cannot use the GPU yet.")
        case "voice.model", "voice.image": return downloadLine(check, facts, locale)
        case "voice.engine": return engineLine(check, facts)
        case "voice.gateway": return gatewayLine(check, facts, locale)
        default: return nil
        }
    }

    func impossibility(of check: SetupCheck, locale: Locale) -> String? {
        let facts = SetupFacts(check.facts)
        switch check.id {
        case "voice.gpu":
            let need = SetupFormat.megabytes(facts.integer("needMB") ?? VoiceRequirements.gpuMemoryMB, locale: locale)
            guard let name = facts.text("name"), let memory = facts.integer("vramMB") else {
                return Localized.text("it has no NVIDIA GPU with %@", need)
            }
            return Localized.text(
                "its %1$@ has %2$@ and voice needs %3$@", name, SetupFormat.megabytes(memory, locale: locale), need)
        default:
            return nil
        }
    }

    func fixLabel(of fix: SetupFix) -> String? {
        switch fix.id {
        case "voice.downloadModel": return Localized.text("Download the voice model")
        case "voice.pullImage": return Localized.text("Download the engine image")
        case "voice.startEngine": return Localized.text("Start the voice engine")
        case "voice.installDocker": return Localized.text("Install Docker")
        case "voice.enableCdi": return Localized.text("Let containers use the GPU")
        case VoiceBridgeInstall.installFixID: return Localized.text("Install voice calls")
        default: return nil
        }
    }

    func fixReason(of fix: SetupFix) -> String? {
        switch fix.id {
        case "voice.installDocker":
            return Localized.text(
                "Installing Docker needs administrator rights, so this one is yours to run in a shell on the machine.")
        case "voice.enableCdi":
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
        case "voice.startEngine": return Localized.text("starting the voice engine")
        default: return nil
        }
    }

    private func gpuLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let need = SetupFormat.megabytes(facts.integer("needMB") ?? VoiceRequirements.gpuMemoryMB, locale: locale)
        let memory = facts.integer("vramMB").map { SetupFormat.megabytes($0, locale: locale) }
        let name = facts.text("name")
        if check.state == .ok {
            switch (name, memory) {
            case (let name?, let memory?): return Localized.text("%1$@, %2$@", name, memory)
            case (let name?, nil): return name
            default: return Localized.text("An NVIDIA GPU was found")
            }
        }
        if let name, let memory {
            return Localized.text("%1$@ has %2$@. Voice calls need %3$@.", name, memory, need)
        }
        return Localized.text("No NVIDIA GPU with %@ was found.", need)
    }

    private func vramLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let free = facts.integer("freeMB").map { SetupFormat.megabytes($0, locale: locale) }
        let need = SetupFormat.megabytes(facts.integer("needMB") ?? VoiceRequirements.engineMemoryMB, locale: locale)
        if check.state == .ok {
            return free.map { Localized.text("%@ free", $0) } ?? Localized.text("Enough memory is free")
        }
        guard let free else {
            return Localized.text("The voice model needs %@ of free GPU memory.", need)
        }
        return Localized.text(
            "Only %1$@ of the GPU is free and the voice model needs %2$@. Something else is using it, and voice calls never stop another job.",
            free, need)
    }

    private func dockerLine(_ check: SetupCheck, _ facts: SetupFacts) -> String {
        if check.state == .ok {
            return facts.text("version").map { Localized.text("Docker %@ is installed", $0) }
                ?? Localized.text("Docker is installed")
        }
        return Localized.text("Docker is not installed, or this account cannot use it.")
    }

    private func downloadLine(_ check: SetupCheck, _ facts: SetupFacts, _ locale: Locale) -> String {
        let size = facts.integer("bytes").map { SetupFormat.bytes($0, locale: locale) }
        switch (check.state, size) {
        case (.ok, let size?): return Localized.text("%@ on this machine", size)
        case (.ok, nil): return Localized.text("On this machine")
        case (.working, _): return Localized.text("Downloading")
        case (_, let size?): return Localized.text("%@ to download", size)
        default: return Localized.text("Not on this machine yet")
        }
    }

    private func engineLine(_ check: SetupCheck, _ facts: SetupFacts) -> String {
        let engine = VoiceEngineState(rawValue: facts.text("engine") ?? "")
        switch (check.state, engine) {
        case (.working, _), (_, .loading?): return Localized.text("Starting. This can take a few minutes.")
        case (_, .ready?): return Localized.text("Running")
        case (_, .busy?): return Localized.text("The GPU is busy with another job")
        case (_, .down?): return Localized.text("Not running")
        case (.ok, _): return Localized.text("Starts when you call and stops after ten idle minutes")
        default: return Localized.text("Waits for the steps above")
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
