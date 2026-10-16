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
            "name": "RTX PRO 6000", "totalMB": "97887", "freeMB": "2048", "needMB": "67584", "bytes": "46868000000",
            "needBytes": "46868000000", "os": "arch", "state": "stopped", "mode": "managed", "progress": "0.4",
            "reason": "docker exited", "after": "voice.docker", "toolkit": "installed", "version": "0.4.0",
        ]
    }

    @Test("The GPU says what it is and what it lacks, as the gateway reports it")
    func gpu() {
        let ok = SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "NVIDIA RTX PRO 6000 Blackwell"])
        #expect(SetupReading.line(of: ok, locale: english) == "NVIDIA RTX PRO 6000 Blackwell")
        let none = SetupCheck(id: "voice.gpu", state: .unavailable, detail: "No NVIDIA GPU was found on this machine.")
        #expect(SetupReading.line(of: none, locale: english) == "No NVIDIA GPU with 80 GB was found.")
        #expect(SetupReading.impossibility(of: none, locale: english) == "it has no NVIDIA GPU with 80 GB")
        let small = SetupCheck(id: "voice.vram", state: .unavailable, facts: ["totalMB": "24564", "needMB": "70000"])
        #expect(SetupReading.line(of: small, locale: english) == "This GPU has 24 GB of memory and voice calls need a card with 80 GB.")
        #expect(SetupReading.impossibility(of: small, locale: english) == "its GPU has 24 GB of memory and voice needs 80 GB")
        let unread = SetupCheck(id: "voice.vram", state: .unavailable, detail: "The card's memory size could not be read.")
        #expect(SetupReading.impossibility(of: unread, locale: english) == "The card's memory size could not be read.")
        let skipped = SetupCheck(id: "voice.docker", state: .unavailable)
        #expect(SetupReading.line(of: skipped, locale: english) == "Not possible on this machine")
    }

    @Test("A busy engine is a fact about someone else's job, said without blame")
    func engineBusy() {
        let check = SetupCheck(
            id: "voice.engine", state: .blocked, facts: ["state": "busy", "freeMB": "2048", "needMB": "70000", "holders": "ollama"])
        let line = SetupReading.line(of: check, locale: english) ?? ""
        #expect(line.hasPrefix("Only 2 GB of the GPU is free and the voice model needs 68 GB."))
        #expect(line.contains("never stop another job"))
        let down = SetupCheck(id: "voice.engine", state: .blocked, facts: ["state": "down", "reason": "container exited"])
        #expect(SetupReading.line(of: down, locale: english) == "Not running: container exited")
        let loading = SetupCheck(id: "voice.engine", state: .working, facts: ["state": "loading", "progress": "0.40"])
        #expect(SetupReading.line(of: loading, locale: english) == "Starting, 40%. This can take a few minutes.")
        let stopped = SetupCheck(id: "voice.engine", state: .ok, facts: ["state": "stopped"])
        #expect(SetupReading.line(of: stopped, locale: english) == "Starts when you call and stops after ten idle minutes")
    }

    @Test("A check waiting on another says which, and is not a blocker")
    func waiting() {
        let image = SetupCheck(id: "voice.image", state: .todo, facts: ["after": "voice.docker"])
        #expect(SetupReading.line(of: image, locale: english) == "Waits for Docker")
    }

    @Test("A download names what is left to fetch, and a fix says what it costs before it starts")
    func downloads() {
        let model = SetupCheck(
            id: "voice.model", state: .todo, facts: ["bytes": "0", "needBytes": "46868000000"],
            fix: SetupFix(id: "voice.downloadModel", bytes: 46_868_000_000, minutes: 12))
        #expect(SetupReading.line(of: model, locale: english) == "44 GB to download")
        #expect(SetupReading.fixLabel(of: model.fix!) == "Download the voice model")
        #expect(SetupReading.fixCost(of: model.fix!, locale: english) == "44 GB, about 12 minutes")
        let resumed = SetupCheck(id: "voice.model", state: .todo, facts: ["bytes": "23434000000", "needBytes": "46868000000"])
        #expect(SetupReading.line(of: resumed, locale: english) == "22 GB to download")
        let installed = SetupCheck(id: "voice.image", state: .ok, facts: ["bytes": "22543587937", "needBytes": "22500000000"])
        #expect(SetupReading.line(of: installed, locale: english) == "21 GB on this machine")
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
            id: "j", fix: "voice.downloadModel", state: .failed, failure: "noDisk",
            facts: ["freeMB": "9216", "needMB": "44700"])
        #expect(
            SetupReading.failure(of: full, locale: english) == "There is not enough room on the disk: 9 GB free, 44 GB needed.")
        #expect(
            SetupReading.failure(of: SetupJob(id: "j", fix: "a", state: .failed, failure: "denied"))?.contains("refused access") == true)
        #expect(
            SetupReading.failure(of: SetupJob(id: "j", fix: "a", state: .failed, failure: "interrupted"))?.contains("interrupted") == true)
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
        job.step = "permissions"
        #expect(SetupReading.jobLine(job, eta: nil, locale: english) == "Finishing up")
        job.step = "mystery"
        #expect(SetupReading.jobLine(job, eta: nil, locale: english) == nil)
    }

    @Test("A capability can register its own words and they are used for its ids")
    func registration() {
        struct Storage: SetupCapabilityReader {
            let capability = "storage"
            var name: String { "Disk space" }
            var setUpLabel: String { "Set up storage" }
            var readyHeadline: String { "Disk space is ready" }
            var readyActionLabel: String { "Open the disk" }
            func title(of check: SetupCheck) -> String? { check.id == "storage.nodes" ? "Space nodes" : nil }
            func line(of check: SetupCheck, locale: Locale) -> String? {
                check.id == "storage.nodes" ? "The space is missing" : nil
            }
        }
        SetupReading.register(Storage())
        let check = SetupCheck(id: "storage.nodes", state: .todo, detail: "english")
        #expect(SetupReading.title(of: check) == "Space nodes")
        #expect(SetupReading.line(of: check, locale: english) == "The space is missing")
        #expect(SetupReading.name(of: "storage") == "Disk space")
        let other = SetupCheck(id: "storage.models", state: .todo, detail: "The file is missing")
        #expect(SetupReading.line(of: other, locale: english) == "The file is missing")
        #expect(SetupReading.name(of: "preview") == "Preview")
    }
}
