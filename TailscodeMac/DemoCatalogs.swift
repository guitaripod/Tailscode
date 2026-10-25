#if DEBUG
    import CodingAgentKit
    import TailscodeCore

    /// What each demo machine runs, asked once, so a pill, a party card or a seam names a model by its
    /// codename on the first frame instead of by its id until the catalog lands.
    @MainActor
    enum DemoCatalogs {
        static func warm() async {
            for profile in DemoWorld.profiles {
                guard let backend = DemoWorld.backend(for: profile.id) else { continue }
                await ModelCatalogStore.refresh(profileID: profile.id, backend: backend)
            }
        }
    }
#endif
