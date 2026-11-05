// The CBOR subset the protocol speaks: encoding, and decoding with hard limits.
import Foundation

/// Minimal CBOR (RFC 8949) subset for OVMC payloads: unsigned/negative integers, byte and
/// text strings, arrays, text-keyed maps, bool and null. No floats, no indefinite lengths,
/// no tags — the message catalogue never needs them. Decode is strictly validated, and
/// every element is size-capped at OVMC.maxPayload so a hostile peer cannot drive an
/// allocation by lying about lengths.
public nonisolated enum CBOR: Sendable {
    /// Why a payload was refused.
    public enum DecodeError: Error, Equatable, Sendable {
        case unexpectedEnd
        case unsupportedMajor(Int)  // floated, tags, templates… (major 6, 7 non-leaf)
        case integerOverflow  // value does not fit our Int64 subset
        case sizeLimitExceeded  // length larger than OVMC.maxPayload
        case badMapKey  // map keys must be text
        case badUTF8
        case trailingGarbage  // bytes after the first value
        case nestingTooDeep  // arrays/maps nested beyond CBOR.maxDepth
    }

    /// Deepest array/map nesting a decoder accepts. The message catalogue never
    /// nests more than three levels; the cap exists because decoding is
    /// recursive, so a hostile peer (a guest) sending `[[[[…]]]]` one byte per
    /// level could otherwise overflow the host daemon's stack.
    public static let maxDepth = 32

    indirect case uint(UInt64)
    indirect case negInt(Int64)  // the value as written, i.e. negative: -n
    indirect case bytes(Data)
    indirect case text(String)
    indirect case array([CBOR])
    indirect case map([(key: String, value: CBOR)])
    case bool(Bool)
    case null

    // MARK: encode

    /// The canonical encoding of this value.
    public func encoded() -> Data {
        var d = Data()
        encode(into: &d)
        return d
    }

    private func encode(into d: inout Data) {
        switch self {
        case .uint(let v): head(into: &d, major: 0, value: v)
        case .negInt(let n):
            // stored argument is the magnitude minus one: -n-1 (respects Int64.min)
            let mag = n == Int64.min ? UInt64(Int64.max) : UInt64(-n - 1)
            head(into: &d, major: 1, value: mag)
        case .bytes(let b):
            head(into: &d, major: 2, value: UInt64(b.count))
            d.append(b)
        case .text(let s):
            let b = Data(s.utf8)
            head(into: &d, major: 3, value: UInt64(b.count))
            d.append(b)
        case .array(let a):
            head(into: &d, major: 4, value: UInt64(a.count))
            for v in a { v.encode(into: &d) }
        case .map(let m):
            head(into: &d, major: 5, value: UInt64(m.count))
            for kv in m {
                let kb = Data(kv.key.utf8)
                head(into: &d, major: 3, value: UInt64(kb.count))
                d.append(kb)
                kv.value.encode(into: &d)
            }
        case .bool(let b): d.append(b ? 0xF5 : 0xF4)
        case .null: d.append(0xF6)
        }
    }

    private func head(into d: inout Data, major: UInt8, value: UInt64) {
        let m = major << 5
        switch value {
        case 0...23:
            d.append(m | UInt8(value))
        case 24...255:
            d.append(m | 24)
            d.append(UInt8(truncatingIfNeeded: value))
        case 256...0xFFFF:
            d.append(m | 25)
            d.append(contentsOf: [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        case 0x10000...0xFFFF_FFFF:
            d.append(m | 26)
            d.append(contentsOf: [
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
            ])
        default:
            d.append(m | 27)
            d.append(contentsOf: [
                UInt8(truncatingIfNeeded: value >> 56), UInt8(truncatingIfNeeded: value >> 48),
                UInt8(truncatingIfNeeded: value >> 40), UInt8(truncatingIfNeeded: value >> 32),
                UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
            ])
        }
    }

    // MARK: decode

    /// Decodes one complete value, refusing anything outside the subset.
    public static func decode(_ data: Data) throws -> CBOR {
        var d = Subdata(data)
        let v = try decode(&d, depth: 0)
        if !d.isEmpty { throw DecodeError.trailingGarbage }
        return v
    }

    private struct Subdata {
        let base: Data
        var index: Int
        init(_ d: Data) {
            base = d
            index = d.startIndex
        }
        var isEmpty: Bool { index >= base.endIndex }
        mutating func pop() -> UInt8 {
            defer { index += 1 }
            return base[index]
        }
        mutating func take(_ n: Int) -> Data? {
            guard index + n <= base.endIndex else { return nil }
            defer { index += n }
            return base.subdata(in: index..<index + n)
        }
    }

    private static func decode(_ d: inout Subdata, depth: Int) throws -> CBOR {
        guard depth <= maxDepth else { throw DecodeError.nestingTooDeep }
        guard !d.isEmpty else { throw DecodeError.unexpectedEnd }
        let first = d.pop()
        let major = Int(first >> 5)
        let extra = Int(first & 0x1F)
        let arg: UInt64
        switch extra {
        case 0...23: arg = UInt64(extra)
        case 24: arg = try uarg(&d, 1)
        case 25: arg = try uarg(&d, 2)
        case 26: arg = try uarg(&d, 4)
        case 27: arg = try uarg(&d, 8)
        default: throw DecodeError.unsupportedMajor(major)  // 28–31: indefinite/reserved
        }
        switch major {
        case 0: return .uint(arg)
        case 1:
            guard arg <= UInt64(Int64.max) else { throw DecodeError.integerOverflow }
            return .negInt(-1 - Int64(bitPattern: arg))
        case 2:
            let b = try takeCapped(&d, arg)
            return .bytes(b)
        case 3:
            let b = try takeCapped(&d, arg)
            guard let s = String(data: b, encoding: .utf8) else { throw DecodeError.badUTF8 }
            return .text(s)
        case 4:
            try checkCap(arg)
            var a: [CBOR] = []
            for _ in 0..<Int(arg) { a.append(try decode(&d, depth: depth + 1)) }
            return .array(a)
        case 5:
            try checkCap(arg)
            var m: [(key: String, value: CBOR)] = []
            for _ in 0..<Int(arg) {
                guard case .text(let k) = try decode(&d, depth: depth + 1) else {
                    throw DecodeError.badMapKey
                }
                m.append((key: k, value: try decode(&d, depth: depth + 1)))
            }
            return .map(m)
        case 6: throw DecodeError.unsupportedMajor(major)  // tags
        case 7:  // simple values — only the constants we encode
            switch arg {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw DecodeError.unsupportedMajor(major)
            }
        default: throw DecodeError.unsupportedMajor(major)  // unreachable, keeps the switch exhaustive
        }
    }

    private static func uarg(_ d: inout Subdata, _ n: Int) throws -> UInt64 {
        guard let b = d.take(n) else { throw DecodeError.unexpectedEnd }
        var v: UInt64 = 0
        for byte in b { v = v << 8 | UInt64(byte) }
        return v
    }

    private static func checkCap(_ arg: UInt64) throws {
        guard arg <= UInt64(OVMC.maxPayload) else { throw DecodeError.sizeLimitExceeded }
    }

    private static func takeCapped(_ d: inout Subdata, _ arg: UInt64) throws -> Data {
        try checkCap(arg)
        guard let bytes = d.take(Int(arg)) else { throw DecodeError.unexpectedEnd }
        return bytes
    }
}

// Synthesised Equatable cannot handle the indirect recursive cases; a manual
// == keeps this a value type.
nonisolated extension CBOR: Equatable {
    public static func == (lhs: CBOR, rhs: CBOR) -> Bool {
        switch (lhs, rhs) {
        case (.uint(let a), .uint(let b)): return a == b
        case (.negInt(let a), .negInt(let b)): return a == b
        case (.bytes(let a), .bytes(let b)): return a == b
        case (.text(let a), .text(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.map(let a), .map(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }
}
