import AppKit
import Foundation
import TailscodeCore

/// The Studio's pure logic, checked headlessly from `--selftest`: how the machine's folder and the
/// session become one shelf, what the stage says in each state of the slot, which verbs a stage
/// offers, what the chips show, when the shell folds a piece of itself and which key is which. None
/// of it needs a window or a machine — those are looked at with `--open studio:<state>`.
@MainActor
enum StudioCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        shelf(expect)
        stage(expect)
        verbs(expect)
        chips(expect)
        folding(expect)
        keys(expect)
        clipShelf(expect)
        videoStage(expect)
        videoVerbs(expect)
        videoChips(expect)
        clipNames(expect)
        startFrom(expect)
        progressLine(expect)
        videoChanges(expect)
        laneSwitch(expect)
        videoContinue(expect)
        videoLanding(expect)
        videoLight(expect)
        videoRing(expect)
        sheetKeys(expect)
        sheetMenu(expect)
        sheet(expect)
        capsulePresses(expect)
        return failures
    }
}
