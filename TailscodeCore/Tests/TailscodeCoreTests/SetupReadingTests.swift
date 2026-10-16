import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Setup reading")
struct SetupReadingTests {
    private let english = Locale(identifier: "en_US")
    private let states: [SetupState] = [.ok, .todo, .working, .blocked, .unavailable]
    private let voiceIDs = [
        "voice.gpu", "voice.vram", "voice.docker", "voice.cdi", "voice.model", "voice.image", "voice.engine",
        "voice.gateway",
    ]

    @Test("Every voice id in every state has a title and a line, with or without facts")
    func everyIDEveryState() {
        for id in voiceIDs {
            for state in states {
                for facts in [[String: String](), richFacts] {
                    let check = SetupCheck(id: id, state: state, facts: facts)
                    #expect(!SetupReading.title(of: check).isEmpty)
                    let line = SetupReading.line(of: check, locale: english)
                    #expect(line?.isEmpty == false, "\(id) \(state)")
                    #expect(line?.contains("%") != true, "\(id) \(state) left a specifier: \(line ?? "")")
                }
            }
        }
    }

    private var richFacts: [String: String] {
        [
            "name": "RTX PRO 6000", "vramMB": "97887", "freeMB": "2048", "needMB": "67584",
            "bytes": "46868000000", "version": "28.0.1", "engine": "stopped",
        ]
    }

    @Test("The GPU says what it has and what voice needs")
    func gpu() {
        let ok = SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "RTX PRO 6000", "vramMB": "97887"])
        #expect(SetupReading.line(of: ok, locale: english) == "RTX PRO 6000, 96 GB")
        let small = SetupCheck(id: "voice.gpu", state: .unavailable, facts: ["name": "RTX 4090", "vramMB": "24564"])
        #expect(SetupReading.line(of: small, locale: english) == "RTX 4090 has 24 GB. Voice calls need 80 GB.")
        #expect(
            SetupReading.impossibility(of: small, locale: english) == "its RTX 4090 has 24 GB and voice needs 80 GB")
        let none = SetupCheck(id: "voice.gpu", state: .unavailable)
        #expect(SetupReading.line(of: none, locale: english) == "No NVIDIA GPU with 80 GB was found.")
        #expect(SetupReading.impossibility(of: none, locale: english) == "it has no NVIDIA GPU with 80 GB")
    }

    @Test("Free memory is a fact about someone else's job, said without blame")
    func vram() {
        let check = SetupCheck(id: "voice.vram", state: .todo, facts: ["freeMB": "2048", "needMB": "67584"])
        let line = SetupReading.line(of: check, locale: english) ?? ""
        #expect(line.hasPrefix("Only 2 GB of the GPU is free and the voice model needs 66 GB."))
        #expect(line.contains("never stop another job"))
    }

    @Test("A download names its size and a fix says what it costs before it starts")
    func downloads() {
        let model = SetupCheck(
            id: "voice.model", state: .todo, facts: ["bytes": "46868000000"],
            fix: SetupFix(id: "voice.downloadModel", bytes: 46_868_000_000, minutes: 12))
        #expect(SetupReading.line(of: model, locale: english) == "44 GB to download")
        #expect(SetupReading.fixLabel(of: model.fix!) == "Download the voice model")
        #expect(SetupReading.fixCost(of: model.fix!, locale: english) == "44 GB, about 12 minutes")
        #expect(SetupReading.fixCost(of: SetupFix(id: "x"), locale: english) == nil)
        #expect(SetupReading.fixCost(of: SetupFix(id: "x", minutes: 1), locale: english) == "about 1 minute")
    }

    @Test("A command fix carries the reason the person is needed")
    func commandReasons() {
        let docker = SetupFix(id: "voice.installDocker", kind: .command, command: "sudo pacman -S docker")
        #expect(SetupReading.fixReason(of: docker)?.contains("administrator rights") == true)
        let unknown = SetupFix(id: "future.thing", kind: .command, command: "x", reason: "needs a reboot")
        #expect(SetupReading.fixReason(of: unknown) == "needs a reboot")
        #expect(SetupReading.fixLabel(of: unknown) == "Copy command")
        #expect(SetupReading.fixLabel(of: SetupFix(id: "future.job")) == "Set it up")
    }

    @Test("An id the app has never seen reads the daemon's own detail, then a neutral line")
    func unknownIDs() {
        let withDetail = SetupCheck(id: "voice.future", state: .todo, detail: "The thing is missing")
        #expect(SetupReading.title(of: withDetail) == "The thing is missing")
        #expect(SetupReading.line(of: withDetail, locale: english) == "The thing is missing")
        let bare = SetupCheck(id: "other.thing", state: .blocked)
        #expect(SetupReading.title(of: bare) == "Something to check")
        #expect(SetupReading.line(of: bare, locale: english) == "Needs attention")
        #expect(SetupReading.impossibility(of: SetupCheck(id: "x.y", state: .unavailable, detail: "no kernel module")) == "no kernel module")
    }

    @Test("A job's failure id is read with its facts, and an unknown one still says something true")
    func failures() {
        let full = SetupJob(
            id: "j", fix: "voice.downloadModel", state: .failed, failure: "diskFull",
            facts: ["freeMB": "9216", "needMB": "44700"])
        #expect(
            SetupReading.failure(of: full, locale: english) == "There is not enough room on the disk: 9 GB free, 44 GB needed.")
        let strange = SetupJob(id: "j", fix: "x.y", state: .failed, failure: "meteor")
        #expect(SetupReading.failure(of: strange, locale: english)?.contains("picks up where it left off") == true)
        #expect(SetupReading.failure(of: SetupJob(id: "j", fix: "a", state: .cancelled)) == nil)
    }

    @Test("A running job reads bytes and time left, then a percentage, then its step")
    func jobLines() {
        var job = SetupJob(
            id: "j", fix: "voice.downloadModel", state: .running, step: "download", fraction: 0.25,
            bytesDone: 11_000_000_000, bytesTotal: 46_868_000_000)
        #expect(SetupReading.jobLine(job, eta: 8 * 60 + 5, locale: english) == "10 of 44 GB, about 8 minutes left")
        #expect(SetupReading.jobLine(job, eta: nil, locale: english) == "10 of 44 GB")
        job.bytesDone = nil
        job.bytesTotal = nil
        #expect(SetupReading.jobLine(job, eta: 120, locale: english) == "25%, about 2 minutes left")
        job.fraction = nil
        #expect(SetupReading.jobLine(job, eta: nil, locale: english) == "Downloading")
        job.step = "mystery"
        #expect(SetupReading.jobLine(job, eta: nil, locale: english) == nil)
    }

    @Test("A capability can register its own words and they are used for its ids")
    func registration() {
        struct Media: SetupCapabilityReader {
            let capability = "media"
            var name: String { "Images and video" }
            var setUpLabel: String { "Set up media" }
            var readyHeadline: String { "Images and video are ready" }
            var readyActionLabel: String { "Open the studio" }
            func title(of check: SetupCheck) -> String? { check.id == "media.nodes" ? "ComfyUI nodes" : nil }
            func line(of check: SetupCheck, locale: Locale) -> String? {
                check.id == "media.nodes" ? "The video nodes are missing" : nil
            }
        }
        SetupReading.register(Media())
        let check = SetupCheck(id: "media.nodes", state: .todo, detail: "english")
        #expect(SetupReading.title(of: check) == "ComfyUI nodes")
        #expect(SetupReading.line(of: check, locale: english) == "The video nodes are missing")
        #expect(SetupReading.name(of: "media") == "Images and video")
        let other = SetupCheck(id: "media.models", state: .todo, detail: "The model file is missing")
        #expect(SetupReading.line(of: other, locale: english) == "The model file is missing")
        #expect(SetupReading.name(of: "preview") == "Preview")
    }
}
