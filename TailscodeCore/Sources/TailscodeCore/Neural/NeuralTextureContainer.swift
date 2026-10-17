import Foundation

/// How a texture's bytes are stored.
public enum NeuralPixelFormat: UInt8, Sendable, CaseIterable {
    case rgba8 = 0
    case astc4x4 = 1
    case astc6x6 = 2

    /// The footprint in pixels of one stored block; an uncompressed pixel is a block of one.
    public var blockSize: (width: Int, height: Int) {
        switch self {
        case .rgba8: return (1, 1)
        case .astc4x4: return (4, 4)
        case .astc6x6: return (6, 6)
        }
    }

    public var bytesPerBlock: Int { self == .rgba8 ? 4 : 16 }

    /// The bytes one level of this size occupies, or nil when the size is empty or overflows.
    public func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let block = blockSize
        let blocksAcross = width / block.width + (width % block.width == 0 ? 0 : 1)
        let blocksDown = height / block.height + (height % block.height == 0 ? 0 : 1)
        let blocks = blocksAcross.multipliedReportingOverflow(by: blocksDown)
        guard !blocks.overflow else { return nil }
        let total = blocks.partialValue.multipliedReportingOverflow(by: bytesPerBlock)
        return total.overflow ? nil : total.partialValue
    }
}

/// The Apple GPU's texture file: what the packing script writes and the Metal loader uploads with
/// no decode. Little-endian throughout: the magic `NTEX`, a 16-bit version, the pixel format, one
/// reserved zero byte, width, height and mip count as 32-bit integers, one 32-bit byte length per
/// mip, then the mips' bytes back to back, largest first. A reader trusts none of it: any
/// short, long, inconsistent or oversized buffer is nil, never a crash.
public struct NeuralTextureContainer: Sendable, Equatable {
    public static let magic: [UInt8] = Array("NTEX".utf8)
    public static let version: UInt16 = 1
    public static let maxDimension = 16384
    public static let maxMipCount = 15

    public let format: NeuralPixelFormat
    public let width: Int
    public let height: Int
    public let mips: [Data]

    /// Nil unless every mip is exactly the size its level needs in this format.
    public init?(format: NeuralPixelFormat, width: Int, height: Int, mips: [Data]) {
        guard width > 0, height > 0, width <= Self.maxDimension, height <= Self.maxDimension,
            !mips.isEmpty, mips.count <= Self.maxMipCount,
            mips.count <= Self.maxMipLevels(width: width, height: height)
        else { return nil }
        for (level, mip) in mips.enumerated() {
            let size = Self.mipSize(width: width, height: height, level: level)
            guard let expected = format.byteCount(width: size.width, height: size.height),
                mip.count == expected
            else { return nil }
        }
        self.format = format
        self.width = width
        self.height = height
        self.mips = mips
    }

    public var mipCount: Int { mips.count }

    public var byteCount: Int { mips.reduce(0) { $0 + $1.count } }

    /// How many levels a full chain has down to one pixel.
    public static func maxMipLevels(width: Int, height: Int) -> Int {
        var levels = 1
        var size = max(width, height)
        while size > 1 {
            size /= 2
            levels += 1
        }
        return levels
    }

    public static func mipSize(width: Int, height: Int, level: Int) -> (width: Int, height: Int) {
        (max(1, width >> level), max(1, height >> level))
    }

    static func headerSize(mipCount: Int) -> Int { 20 + 4 * mipCount }

    public func encode() -> Data {
        var data = Data(Self.magic)
        func append32(_ value: Int) {
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        withUnsafeBytes(of: Self.version.littleEndian) { data.append(contentsOf: $0) }
        data.append(format.rawValue)
        data.append(0)
        append32(width)
        append32(height)
        append32(mips.count)
        for mip in mips { append32(mip.count) }
        for mip in mips { data.append(mip) }
        return data
    }

    /// The container in `data`, or nil if it is not exactly one well-formed container.
    public static func decode(_ data: Data) -> NeuralTextureContainer? {
        let bytes = [UInt8](data)
        guard bytes.count >= 20, Array(bytes[0..<4]) == magic else { return nil }
        func read32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
        }
        let found = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        guard found == version, let format = NeuralPixelFormat(rawValue: bytes[6]), bytes[7] == 0,
            let width = read32(8), let height = read32(12), let mipCount = read32(16),
            width > 0, height > 0, width <= maxDimension, height <= maxDimension,
            mipCount > 0, mipCount <= maxMipCount,
            mipCount <= maxMipLevels(width: width, height: height)
        else { return nil }
        let header = headerSize(mipCount: mipCount)
        guard bytes.count >= header else { return nil }
        var lengths: [Int] = []
        var total = 0
        for index in 0..<mipCount {
            guard let length = read32(20 + 4 * index) else { return nil }
            let size = mipSize(width: width, height: height, level: index)
            guard let expected = format.byteCount(width: size.width, height: size.height),
                length == expected
            else { return nil }
            lengths.append(length)
            let sum = total.addingReportingOverflow(length)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        guard bytes.count == header + total else { return nil }
        var mips: [Data] = []
        var offset = header
        for length in lengths {
            mips.append(Data(bytes[offset..<(offset + length)]))
            offset += length
        }
        return NeuralTextureContainer(format: format, width: width, height: height, mips: mips)
    }
}
