import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The questions for later are this computer's to ask, so the window that is always open asks
    /// them: on a half-minute beat, at once when the list changes, and on launch for anything
    /// whose hour passed while the app was closed. The development harness carries the person's
    /// real servers and never asks.
    func startAskingLater() {
        guard !DesktopGuard.isHarnessed else { return }
        laterWatch = NotificationCenter.default.addObserver(
            forName: QuickAskLaterStore.didChange, object: nil, queue: nil
        ) { [weak self] _ in
            Gtk.onMain { [weak self] in self?.askDueLater() }
        }
        laterBeat()
    }

    private func laterBeat() {
        askDueLater()
        Gtk.after(30_000) { [weak self] in self?.laterBeat() }
    }

    /// Each due question is minted and sent with no pane opened for it; it lands in the chat list
    /// like any other, and the window says it was asked. One that fails is tried again in ten
    /// minutes rather than on every beat.
    func askDueLater() {
        let now = Date()
        handOffLater(now: now)
        for later in QuickAskLaterStore.due(now: now) where !laterInFlight.contains(later.id) {
            laterInFlight.insert(later.id)
            Task { [weak self] in
                let profiles = await ServerDirectory.shared.profiles()
                guard let profile = profiles.first(where: { $0.id == later.profileID }),
                    let backend = await ServerDirectory.shared.backend(for: profile)
                else {
                    Gtk.onMain { [weak self] in
                        self?.laterInFlight.remove(later.id)
                        QuickAskLaterStore.postpone(later, by: 600)
                    }
                    return
                }
                let password = await ServerDirectory.shared.password(for: profile)
                let outcome = await QuickAskLaterRunner.ask(
                    later, on: profile, using: backend, password: password)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.laterInFlight.remove(later.id)
                    switch outcome {
                    case .success:
                        QuickAskLaterStore.asked(later, at: Date())
                        AppLog.write(.session, "LATER asked id=\(later.id) server=\(profile.name)")
                        self.toast(Localized.text("Asked for later: %@", later.headline))
                        Task { [weak self] in await self?.refresh() }
                    case .failure(let failure):
                        QuickAskLaterStore.postpone(later, by: 600)
                        AppLog.write(.session, "LATER failed id=\(later.id) \(failure.title)")
                        self.toast("\(failure.title) — \(later.headline)")
                    }
                }
            }
        }
    }

    /// A question put off here goes to its machine when the machine keeps schedules, so it is
    /// asked whether or not this computer is on; the copy here is let go once the machine has it.
    /// One already due is asked here first, and the repeat that follows is handed over after.
    func handOffLater(now: Date) {
        for later in QuickAskLaterStore.all()
        where later.dueAt > now && !laterInFlight.contains(later.id) && !laterStaysHere.contains(later.profileID) {
            laterInFlight.insert(later.id)
            Task { [weak self] in
                let profiles = await ServerDirectory.shared.profiles()
                guard let profile = profiles.first(where: { $0.id == later.profileID }),
                    let backend = await ServerDirectory.shared.backend(for: profile)
                else {
                    Gtk.onMain { [weak self] in self?.laterInFlight.remove(later.id) }
                    return
                }
                let keeps = await MachineFeatures.read(backend).schedules
                let placed =
                    keeps
                    ? await QuickAskLaterHandoff.place(later, using: backend, device: MachineFeatures.deviceName)
                    : false
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.laterInFlight.remove(later.id)
                    guard placed else {
                        if !keeps { self.laterStaysHere.insert(later.profileID) }
                        return
                    }
                    QuickAskLaterStore.remove(id: later.id)
                    AppLog.write(.session, "LATER handed id=\(later.id) server=\(profile.name)")
                    self.toast(Localized.text("Handed to %@: %@", profile.name, later.headline))
                    self.refreshScheduleLine()
                    SchedulesWindow.refreshAll()
                }
            }
        }
    }
}
