import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Voice chime")
struct VoiceChimeTests {
    private func samples(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }

    private func decibels(_ sample: Int16) -> Double {
        20 * log10(Double(abs(Int(sample))) / Double(Int16.max))
    }

    @Test("The finished chime is about 420 ms of whole samples")
    func finishedLength() {
        let data = VoiceChime.finished()
        #expect(data.count % 2 == 0)
        let seconds = Double(data.count / 2) / Double(VoiceWire.sampleRate)
        #expect(abs(seconds - 0.42) < 0.01)
    }

    @Test("The attention chime is about 250 ms of whole samples")
    func attentionLength() {
        let data = VoiceChime.attention()
        #expect(data.count % 2 == 0)
        let seconds = Double(data.count / 2) / Double(VoiceWire.sampleRate)
        #expect(abs(seconds - 0.25) < 0.01)
    }

    @Test("The finished chime peaks near minus 14 dBFS and the attention note is softer")
    func peaks() throws {
        let finished = try #require(samples(VoiceChime.finished()).map { abs(Int($0)) }.max())
        let attention = try #require(samples(VoiceChime.attention()).map { abs(Int($0)) }.max())
        let finishedDB = decibels(Int16(finished))
        #expect(finishedDB < -13.5 && finishedDB > -14.5)
        #expect(attention < finished)
        #expect(decibels(Int16(attention)) < -19)
    }

    @Test("Neither chime clicks at either end")
    func quietEnds() {
        for data in [VoiceChime.finished(), VoiceChime.attention()] {
            let list = samples(data)
            #expect(abs(Int(list[0])) <= 2)
            #expect(abs(Int(list[list.count - 1])) <= 2)
            let head = list.prefix(3).map { abs(Int($0)) }.max() ?? 0
            let tail = list.suffix(24).map { abs(Int($0)) }.max() ?? 0
            #expect(head < 60)
            #expect(tail < 200)
        }
    }

    @Test("Neighbouring samples never jump, so nothing in the chime is a click")
    func smooth() {
        for data in [VoiceChime.finished(), VoiceChime.attention()] {
            let list = samples(data)
            let steps = zip(list, list.dropFirst()).map { abs(Int($1) - Int($0)) }
            #expect((steps.max() ?? 0) < 1_500)
        }
    }

    @Test("The output is the same every time and the two chimes differ")
    func deterministic() {
        #expect(VoiceChime.finished() == VoiceChime.finished())
        #expect(VoiceChime.attention() == VoiceChime.attention())
        #expect(VoiceChime.finished() != VoiceChime.attention())
        #expect(VoiceChime.finished().count != VoiceChime.attention().count)
    }

    @Test("The finished chime has two notes, the second a fifth above the first")
    func twoNotes() {
        let list = samples(VoiceChime.finished())
        func crossings(_ range: Range<Int>) -> Int {
            zip(list[range], list[range].dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        }
        let half = list.count / 2
        let first = Double(crossings(0..<half))
        let second = Double(crossings(half..<list.count))
        #expect(abs(second / first - 1.5) < 0.1)
    }
}
