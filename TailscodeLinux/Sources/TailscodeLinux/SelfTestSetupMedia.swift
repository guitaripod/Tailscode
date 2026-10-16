import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Images and video through the shared checklist on this desk: every fixture state draws the rows
    /// Core wrote, the lane a person came from leads and is what the headline counts, the licensing
    /// facts are said once each, ComfyUI out of reach copies the start command that binds loopback
    /// and the tailnet address only, the checklist names the machine and offers Change, and the pill
    /// and the window both reach the same place.
    static func checkSetupMedia(
        _ expect: (Bool, String) throws -> Void, _ pump: (Double, () -> Bool) -> Bool
    ) throws {
        for name in SetupFixtures.mediaNames {
            guard let snapshot = SetupFixtures.snapshot(named: name) else {
                try expect(false, "\(name): the fixture exists")
                continue
            }
            for focus in [nil, SetupFocus.video, .pictures] {
                let list = SetupChecklist(snapshot: snapshot, focus: focus)
                let view = SetupChecklistView()
                view.apply(list)
                try expect(view.headlineText == list.headline, "\(name): the headline is Core's")
                try expect(view.rowCount == list.rows.count, "\(name): one card per row")
                try expect(view.primaryVisible == (list.primary != nil), "\(name): the button shows only when Core offers one")
                if let primary = list.primary {
                    try expect(view.primaryLabel == primary.label, "\(name): the button's word is Core's")
                }
                try expect(
                    list.place == nil || view.placeText == list.place?.line, "\(name): the machine line is Core's")
                try expect(!view.offersChange, "\(name): and Change is offered only to a window that can change it")
            }
        }

        let bare = try unwrapMedia(SetupFixtures.snapshot(named: "media"))
        let video = SetupChecklist(snapshot: bare, focus: .video)
        try expect(video.headline == "Video needs 5 things", "video leads: \(video.headline)")
        try expect(
            video.rows.map(\.id).prefix(4).elementsEqual([
                "media.comfy", "media.gpu", "media.video.nodes", "media.video.model.videoModel",
            ]), "the video files come in order after the card and the nodes")
        guard case .copy(let command, let label)? = video.primary else {
            throw SelfTestFailure("setup: the video checklist offers a command to copy")
        }
        try expect(label == "Copy command" && command.hasPrefix("hf download Lightricks/LTX-2.5"), "the button copies the next missing file")
        let model = try unwrapMedia(video.rows.first { $0.id == "media.video.model.videoModel" })
        try expect(model.fix?.reason?.contains("hf auth login") == true, "the gate is said on the row that needs it, with the command")
        try expect(
            video.rows.filter { $0.fix?.reason?.contains("gated on Hugging Face") == true && $0.id.hasPrefix("media.video.model.") }.count == 1,
            "and only once")

        let pictures = SetupChecklist(snapshot: bare, focus: .pictures)
        try expect(pictures.headline == "Pictures need 3 things", "pictures lead: \(pictures.headline)")
        let licence = pictures.rows.filter { $0.line?.contains("For personal and research use only") == true }
        try expect(licence.map(\.id) == ["media.image.model.qwenModel"], "the research licence is said once, on the first Qwen row")

        let down = SetupChecklist(snapshot: try unwrapMedia(SetupFixtures.snapshot(named: "media-down")), focus: .video)
        try expect(down.rows.map(\.id) == ["media.comfy"] && down.headline == "ComfyUI is not answering", "ComfyUI out of reach is one row")
        try expect(
            down.primary == .copy(command: ForgeSetup.startCommand, label: "Copy command"),
            "and its button copies the start command")
        try expect(
            !ForgeSetup.startCommand.contains("0.0.0.0") && ForgeSetup.startCommand.contains("127.0.0.1,$ts"),
            "which binds loopback and the tailnet address, never every interface")
        try expect(down.rows.first?.fix?.reason?.contains("Tailscale address") == true, "and the row says what it does when Tailscale has no address")

        let ready = SetupChecklist(snapshot: try unwrapMedia(SetupFixtures.snapshot(named: "media-ready")), focus: .pictures)
        try expect(ready.status == .ready && ready.primary == .finish(label: "Open the studio"), "a ready lane offers the studio")

        var changed = 0
        let flag = FinishFlag()
        let snapshot = try unwrapMedia(SetupFixtures.snapshot(named: "media-video"))
        SetupWindow.present(
            target: snapshot.target, parent: nil, fixture: snapshot, focus: .video, onChange: { flag.raise() })
        guard let window = SetupWindow.current else { throw SelfTestFailure("setup: the media window did not open") }
        try expect(window.viewForHarness.placeText == "ComfyUI at \(SetupFixtures.host):8188", "the window names the machine it checks")
        try expect(window.viewForHarness.offersChange, "and offers Change")
        window.viewForHarness.onChange?()
        _ = pump(0.2) { flag.raised }
        changed += flag.raised ? 1 : 0
        try expect(changed == 1, "Change reaches the picker's door")
        SetupWindow.dismiss()
        _ = pump(0.1) { false }

        let pill = StudioMachineButton()
        let pressed = FinishFlag()
        pill.onPress = { pressed.raise() }
        pill.open()
        try expect(pressed.raised, "the machine pill opens the checklist")
    }

    private static func unwrapMedia<T>(_ value: T?) throws -> T {
        guard let value else { throw SelfTestFailure("setup: a media fixture was missing") }
        return value
    }
}
