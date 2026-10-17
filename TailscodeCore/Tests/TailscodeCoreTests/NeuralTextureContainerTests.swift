import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural texture container")
struct NeuralTextureContainerTests {
    private func make(
        format: NeuralPixelFormat, width: Int, height: Int, levels: Int
    ) -> NeuralTextureContainer {
        var mips: [Data] = []
        for level in 0..<levels {
            let size = NeuralTextureContainer.mipSize(width: width, height: height, level: level)
            let count = format.byteCount(width: size.width, height: size.height) ?? 0
            mips.append(Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ level) }))
        }
        return NeuralTextureContainer(format: format, width: width, height: height, mips: mips)!
    }

    @Test("every format round-trips with its mips")
    func roundTrip() throws {
        for (format, width, height, levels) in [
            (NeuralPixelFormat.rgba8, 13, 9, 4), (.astc4x4, 30, 18, 5), (.astc6x6, 31, 17, 3),
            (.astc6x6, 1, 1, 1),
        ] {
            let container = make(format: format, width: width, height: height, levels: levels)
            let decoded = try #require(NeuralTextureContainer.decode(container.encode()))
            #expect(decoded == container)
            #expect(decoded.mipCount == levels)
            #expect(decoded.format == format)
        }
    }

    @Test("the header is magic, version, format, size and per-mip lengths, little-endian")
    func layout() {
        let container = make(format: .rgba8, width: 4, height: 2, levels: 2)
        let data = [UInt8](container.encode())
        #expect(Array(data[0..<4]) == Array("NTEX".utf8))
        #expect(data[4] == 1 && data[5] == 0)
        #expect(data[6] == 0 && data[7] == 0)
        #expect(Array(data[8..<12]) == [4, 0, 0, 0])
        #expect(Array(data[12..<16]) == [2, 0, 0, 0])
        #expect(Array(data[16..<20]) == [2, 0, 0, 0])
        #expect(Array(data[20..<24]) == [32, 0, 0, 0])
        #expect(Array(data[24..<28]) == [8, 0, 0, 0])
        #expect(data.count == 28 + 32 + 8)
    }

    @Test("compressed sizes count whole blocks")
    func blockSizes() {
        #expect(NeuralPixelFormat.astc4x4.byteCount(width: 5, height: 5) == 4 * 16)
        #expect(NeuralPixelFormat.astc6x6.byteCount(width: 6, height: 6) == 16)
        #expect(NeuralPixelFormat.astc6x6.byteCount(width: 7, height: 1) == 32)
        #expect(NeuralPixelFormat.rgba8.byteCount(width: 3, height: 2) == 24)
        #expect(NeuralPixelFormat.rgba8.byteCount(width: 0, height: 2) == nil)
        #expect(NeuralPixelFormat.rgba8.byteCount(width: Int.max, height: Int.max) == nil)
    }

    @Test("every truncation of a container is nil and none crashes")
    func truncation() {
        let encoded = make(format: .astc6x6, width: 20, height: 12, levels: 3).encode()
        for length in 0..<encoded.count {
            #expect(NeuralTextureContainer.decode(encoded.prefix(length)) == nil)
        }
        #expect(NeuralTextureContainer.decode(encoded) != nil)
    }

    @Test("trailing bytes, a wrong length, a bad magic, a bad version or a bad format are nil")
    func corruption() {
        let encoded = make(format: .rgba8, width: 8, height: 4, levels: 2).encode()
        #expect(NeuralTextureContainer.decode(encoded + Data([0])) == nil)

        func mutated(_ index: Int, _ value: UInt8) -> Data {
            var copy = encoded
            copy[index] = value
            return copy
        }
        #expect(NeuralTextureContainer.decode(mutated(0, 0x58)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(4, 2)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(6, 9)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(7, 1)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(8, 0)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(12, 0)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(16, 0)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(16, 9)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(20, 31)) == nil)
        #expect(NeuralTextureContainer.decode(mutated(11, 0x7f)) == nil)
    }

    @Test("absurd sizes and mip counts are refused without allocating")
    func absurd() {
        var data = Data("NTEX".utf8)
        data.append(contentsOf: [1, 0, 0, 0])
        for value in [UInt32(0x7fff_ffff), 0x7fff_ffff, 15] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        #expect(NeuralTextureContainer.decode(data) == nil)
        #expect(NeuralTextureContainer.decode(Data(repeating: 0xff, count: 64)) == nil)
        #expect(NeuralTextureContainer.decode(Data()) == nil)
    }

    @Test("the memberwise initialiser refuses mips of the wrong size or count")
    func initValidation() {
        let one = Data(count: 16)
        #expect(NeuralTextureContainer(format: .rgba8, width: 2, height: 2, mips: [one]) != nil)
        #expect(NeuralTextureContainer(format: .rgba8, width: 2, height: 2, mips: [Data(count: 15)]) == nil)
        #expect(NeuralTextureContainer(format: .rgba8, width: 2, height: 2, mips: []) == nil)
        #expect(
            NeuralTextureContainer(format: .rgba8, width: 2, height: 2, mips: [one, Data(count: 4), Data(count: 4)])
                == nil)
        #expect(NeuralTextureContainer(format: .rgba8, width: 0, height: 2, mips: [one]) == nil)
        #expect(NeuralTextureContainer(format: .rgba8, width: 20000, height: 1, mips: [one]) == nil)
    }

    @Test("a full mip chain runs down to one pixel")
    func chain() {
        #expect(NeuralTextureContainer.maxMipLevels(width: 1536, height: 1008) == 11)
        #expect(NeuralTextureContainer.maxMipLevels(width: 1, height: 1) == 1)
        let size = NeuralTextureContainer.mipSize(width: 1536, height: 1008, level: 10)
        #expect(size.width == 1 && size.height == 1)
    }
}
