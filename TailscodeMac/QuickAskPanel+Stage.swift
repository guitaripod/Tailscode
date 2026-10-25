#if DEBUG
    import AppKit
    import CodingAgentKit
    import TailscodeCore

    extension QuickAskPanel {
        /// The party opened over the demo fleet once each machine has said what it runs, aimed at the
        /// first machine so a take of the local slot crosses to the other — `--open quickask:party`
        /// from the command line, and `quickask:take` after that take has been made.
        func stageParty(takes: Bool) {
            DialTour.fillFleetParty()
            RecentModelsStore.record(ModelSelection(providerID: "google", modelID: "gemini-3-pro"))
            RecentModelsStore.record(
                ModelSelection(providerID: "anthropic", modelID: "claude-haiku-4-5"))
            Task { @MainActor [weak self] in
                await DemoCatalogs.warm()
                guard let self else { return }
                if servers.contains(where: { $0.id == DemoWorld.claudeProfile.id }) {
                    aim(at: DemoWorld.claudeProfile.id)
                    refreshAim()
                }
                guard takes else {
                    openModelParty()
                    return
                }
                applyPreset(number: 4)
            }
        }
    }
#endif
