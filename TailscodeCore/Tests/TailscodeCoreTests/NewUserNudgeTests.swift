import Foundation
import Testing

@testable import TailscodeCore

extension DeviceStores {
    @Suite("New-user nudges", .serialized)
    struct NewUserNudgeTests {
        private static let keys = [
            NotificationPrimer.offeredKey, DemoNudge.dismissedKey, DemoMode.defaultsKey,
        ]

        private func withCleanStore(_ body: () -> Void) {
            let defaults = UserDefaults.standard
            let previous = Self.keys.map { ($0, defaults.object(forKey: $0)) }
            for key in Self.keys { defaults.removeObject(forKey: key) }
            body()
            for (key, value) in previous {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        @Test("The notification question is offered once and never again")
        func primerOnce() {
            withCleanStore {
                #expect(NotificationPrimer.shouldOffer(systemAnswerPending: true, isDemo: false))
                NotificationPrimer.markOffered()
                #expect(!NotificationPrimer.shouldOffer(systemAnswerPending: true, isDemo: false))
            }
        }

        @Test("The demo never asks, and neither does a system that has already answered")
        func primerGates() {
            withCleanStore {
                #expect(!NotificationPrimer.shouldOffer(systemAnswerPending: true, isDemo: true))
                #expect(!NotificationPrimer.shouldOffer(systemAnswerPending: false, isDemo: false))
                #expect(!NotificationPrimer.hasOffered)
            }
        }

        @Test("The demo card shows in the demo until it is set aside")
        func nudgeDismissal() {
            withCleanStore {
                #expect(DemoNudge.isShown(demoActive: true))
                #expect(!DemoNudge.isShown(demoActive: false))
                DemoNudge.dismiss()
                #expect(!DemoNudge.isShown(demoActive: true))
            }
        }

        @Test("Entering the demo again brings the card back")
        func nudgeResetsOnEntry() {
            withCleanStore {
                DemoNudge.dismiss()
                DemoMode.enter()
                #expect(DemoNudge.isShown(demoActive: DemoMode.isActive))
                DemoMode.leave()
                #expect(!DemoNudge.isShown(demoActive: DemoMode.isActive))
            }
        }

        @Test("The handoff carries the install command verbatim between the other two steps")
        func handoffMessage() {
            let command = "curl -fsSL https://example.com/install.sh | BRIDGE_PASSWORD=abc bash"
            let message = SetupHandoff.message(installCommand: command)
            #expect(message.contains(SetupHandoff.tailscaleDownloadURL))
            #expect(message.contains("\n\(command)\n"))
            #expect(message.hasSuffix(SetupHandoff.addressCommand))
            let order = [SetupHandoff.tailscaleDownloadURL, command, SetupHandoff.addressCommand]
                .compactMap { message.range(of: $0)?.lowerBound }
            #expect(order == order.sorted() && order.count == 3)
        }
    }
}
