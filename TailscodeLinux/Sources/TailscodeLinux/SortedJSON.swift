import Foundation

/// A JSON writer for the settings file that orders keys by their UTF-8 bytes.
///
/// `JSONSerialization` with `.sortedKeys` orders them with a locale-aware string comparison, which
/// on corelibs costs about fifty milliseconds for the fifteen hundred keys the file holds, every
/// time it is written. Byte order is the same on every machine and run, which is all the writer
/// needs from an order: the encoded bytes are compared with the last write, so they must not move
/// unless a value did.
enum SortedJSON {
    /// Pretty-printed JSON for a dictionary of property-list values, or nil for a value JSON
    /// cannot carry, so a caller can fall back to the system encoder.
    static func encode(_ object: [String: Any]) -> Data? {
        var out = [UInt8]()
        out.reserveCapacity(1 << 20)
        guard write(object, depth: 0, into: &out) else { return nil }
        return Data(out)
    }

    private static func write(_ value: Any, depth: Int, into out: inout [UInt8]) -> Bool {
        switch value {
        case let text as String:
            writeString(text, into: &out)
        case let number as NSNumber:
            return writeNumber(number, into: &out)
        case is NSNull:
            out.append(contentsOf: "null".utf8)
        case let array as [Any]:
            guard !array.isEmpty else {
                out.append(contentsOf: "[]".utf8)
                return true
            }
            out.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(depth + 1, into: &out)
                guard write(element, depth: depth + 1, into: &out) else { return false }
            }
            newline(depth, into: &out)
            out.append(UInt8(ascii: "]"))
        case let dictionary as [String: Any]:
            guard !dictionary.isEmpty else {
                out.append(contentsOf: "{}".utf8)
                return true
            }
            out.append(UInt8(ascii: "{"))
            let keys = dictionary.keys.sorted()
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(depth + 1, into: &out)
                writeString(key, into: &out)
                out.append(contentsOf: " : ".utf8)
                guard let element = dictionary[key],
                    write(element, depth: depth + 1, into: &out)
                else { return false }
            }
            newline(depth, into: &out)
            out.append(UInt8(ascii: "}"))
        default:
            return false
        }
        return true
    }

    private static func writeNumber(_ number: NSNumber, into out: inout [UInt8]) -> Bool {
        let type = String(cString: number.objCType)
        switch type {
        case "c", "B":
            out.append(contentsOf: (number.boolValue ? "true" : "false").utf8)
        case "d", "f":
            return writeDouble(number.doubleValue, into: &out)
        case "Q":
            out.append(contentsOf: String(number.uint64Value).utf8)
        default:
            out.append(contentsOf: String(number.int64Value).utf8)
        }
        return true
    }

    private static func writeDouble(_ real: Double, into out: inout [UInt8]) -> Bool {
        guard real.isFinite else { return false }
        if real == real.rounded(), abs(real) < 1e15 {
            out.append(contentsOf: String(Int64(real)).utf8)
        } else {
            out.append(contentsOf: "\(real)".utf8)
        }
        return true
    }

    private static func newline(_ depth: Int, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\n"))
        for _ in 0..<depth { out.append(contentsOf: [0x20, 0x20]) }
    }

    private static func writeString(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        var plain = text
        let escaped: Bool = plain.withUTF8 { bytes in
            var clean = true
            for byte in bytes where byte < 0x20 || byte == 0x22 || byte == 0x5C {
                clean = false
                break
            }
            if clean { out.append(contentsOf: bytes) }
            return !clean
        }
        if escaped {
            for byte in text.utf8 {
                switch byte {
                case UInt8(ascii: "\""): out.append(contentsOf: [0x5C, 0x22])
                case UInt8(ascii: "\\"): out.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
                case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
                case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
                case 0..<0x20:
                    out.append(contentsOf: String(format: "\\u%04x", byte).utf8)
                default: out.append(byte)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}
