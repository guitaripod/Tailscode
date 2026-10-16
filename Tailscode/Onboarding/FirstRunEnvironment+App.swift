import TailscodeCore
import UIKit

extension FirstRunEnvironment {
    @MainActor
    static func app() -> FirstRunEnvironment {
        FirstRunEnvironment(
            profiles: {
                await MainActor.run {
                    ConnectionController.shared.profiles.filter {
                        !$0.id.hasPrefix(DemoWorld.profilePrefix)
                    }
                }
            },
            save: { profile, password in
                await MainActor.run {
                    do {
                        try ConnectionController.shared.save(profile, password: password)
                        return .saved
                    } catch is ConnectionController.ProRequired {
                        return .needsPro
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }
            },
            log: { AppLogger.connection.info($0) })
    }
}

extension FirstRunPlatform {
    @MainActor
    static var current: FirstRunPlatform { DeviceWord.isPad ? .iPad : .iPhone }
}
