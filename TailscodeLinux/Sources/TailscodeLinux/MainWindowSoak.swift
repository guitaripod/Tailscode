import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Opens the soak world's sessions one per pane, waiting for the list to carry them first.
    func soakOpen(_ arrangement: SplitArrangement, attempts: Int) {
        guard let configuration = SoakWorld.configuration else {
            FileHandle.standardOutput.write(Data("SOAKOPEN no soak world\n".utf8))
            return
        }
        let chosen = (1...configuration.panes).compactMap { index in
            entries.first {
                $0.profileID == SoakWorld.profile.id && $0.session.id == SoakWorld.sessionID(index)
            }
        }
        guard chosen.count == configuration.panes else {
            if attempts > 0 {
                Gtk.after(1000) { [weak self] in self?.soakOpen(arrangement, attempts: attempts - 1) }
            } else {
                FileHandle.standardOutput.write(
                    Data("SOAKOPEN missing \(configuration.panes - chosen.count)\n".utf8))
            }
            return
        }
        if chosen.count == 1 {
            open(chosen[0])
        } else {
            let offered = SplitEven.offers(count: chosen.count)
            openSplit(chosen, as: offered.contains(arrangement) ? arrangement : .sideBySide)
        }
        FileHandle.standardOutput.write(Data("SOAKOPEN panes=\(splitHost.paneCount)\n".utf8))
    }

    /// One prompt into every pane in the same main-loop turn, so every reply streams at once.
    func soakSend() {
        let panes = splitHost.orderedPanes
        for (index, pane) in panes.enumerated() {
            pane.sendComposed("Soak turn for pane \(index + 1): write a long answer.")
        }
        FileHandle.standardOutput.write(Data("SOAKSEND panes=\(panes.count)\n".utf8))
    }

    /// Structural verbs and window resizes on a 1.2 s beat for `seconds`, keeping the pane count
    /// where it started: every split is closed again on the next beat.
    func soakHammer(seconds: Int) {
        guard let window else { return }
        let width = gtk_widget_get_width(window)
        let height = gtk_widget_get_height(window)
        let beats = max(1, seconds * 1000 / 1200)
        let cycle = [
            "split", "sclose", "szoom", "szoom", "sxchg", "seq", "sfocus", "shrink", "grow",
        ]
        for beat in 0..<beats {
            Gtk.after(UInt32(beat * 1200)) { [weak self] in
                guard let self, let window = self.window else { return }
                switch cycle[beat % cycle.count] {
                case "split": _ = self.perform(.splitPane(beat % 2 == 0 ? .horizontal : .vertical))
                case "sclose": _ = self.perform(.closeSplit)
                case "szoom": _ = self.perform(.zoomSplit)
                case "sxchg": _ = self.perform(.exchangeSplit)
                case "seq": _ = self.perform(.equalizeSplits)
                case "sfocus": _ = self.perform(.focusSplit(beat % 2 == 0 ? .right : .left))
                case "shrink": gtk_window_set_default_size(ptr(window), width * 2 / 3, height * 3 / 4)
                default: gtk_window_set_default_size(ptr(window), width, height)
                }
            }
        }
        Gtk.after(UInt32(beats * 1200 + 500)) { [weak self] in
            guard let self, let window = self.window else { return }
            gtk_window_set_default_size(ptr(window), width, height)
            _ = self.perform(.equalizeSplits)
            FileHandle.standardOutput.write(
                Data(
                    "SOAKHAMMER done beats=\(beats) panes=\(self.splitHost.paneCount) window=\(gtk_widget_get_width(window))x\(gtk_widget_get_height(window))\n"
                        .utf8))
        }
    }
}
