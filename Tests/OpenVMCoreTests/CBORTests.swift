// Tests for the CBOR codec.
import Foundation
import Testing

@testable import OpenVMCore

private func bytes(_ hex: String) -> Data {
    var cleaned = hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).joined()
    var out = Data()
    var i = cleaned.startIndex
    while i < cleaned.endIndex {
        let hi = UInt8(String(cleaned[i]), radix: 16)!
        i = cleaned.index(after: i)
        let lo = UInt8(String(cleaned[i]), radix: 16)!
        i = cleaned.index(after: i)
        out.append(hi << 4 | lo)
    }
    return out
}

@Suite struct CBORTests {

    @Test func uintGolden() throws {
        #expect(try CBOR.decode(bytes("00")) == .uint(0))  // RFC 8949 §B.1 zero
        #expect(try CBOR.decode(bytes("17")) == .uint(23))
        #expect(try CBOR.decode(bytes("1818")) == .uint(24))
        #expect(try CBOR.decode(bytes("19 03e8")) == .uint(1000))
        #expect(try CBOR.decode(bytes("1a 000f4240")) == .uint(1_000_000))
        #expect(CBOR.uint(1000).encoded() == bytes("19 03e8"))
    }

    @Test func negativeInts() throws {
        #expect(try CBOR.decode(bytes("20")) == .negInt(-1))  // -1 = 0x20
        #expect(try CBOR.decode(bytes("39 03e7")) == .negInt(-1000))
    }

    @Test func textBytesArrayMapGolden() throws {
        #expect(try CBOR.decode(bytes("64 49455446")) == .text("IETF"))
        #expect(try CBOR.decode(bytes("44 01020304")) == .bytes(Data([1, 2, 3, 4])))
        #expect(try CBOR.decode(bytes("82 0102")) == .array([.uint(1), .uint(2)]))
        #expect(try CBOR.decode(bytes("a1 6161 01")) == .map([("a", .uint(1))]))
        #expect(try CBOR.decode(bytes("f5")) == .bool(true))
        #expect(try CBOR.decode(bytes("f4")) == .bool(false))
        #expect(try CBOR.decode(bytes("f6")) == .null)
    }

    @Test func roundTrips() throws {
        let values: [CBOR] = [
            .uint(0), .uint(UInt64.max - 1), .negInt(-1), .negInt(-1000),
            .bytes(Data("payload".utf8)), .text("openVMこんにちは"),
            .array([.uint(1), .text("two")]),
            .map([("a", .uint(1)), ("nested", .map([("b", .bool(true))]))]),
            .bool(false), .null,
        ]
        for v in values {
            #expect(try CBOR.decode(v.encoded()) == v)
        }
    }

    @Test func trailingGarbageAndEnd() {
        #expect(throws: CBOR.DecodeError.trailingGarbage) {
            try CBOR.decode(bytes("00 01"))
        }
        #expect(throws: CBOR.DecodeError.unexpectedEnd) {
            try CBOR.decode(bytes("64 4945"))  // "IETF", truncated
        }
    }

    @Test func hostileLengthIsRejectedWithoutAllocation() {
        // text with declared length 0xFFFFFFFF (4-byte length head 0x7A):
        // must fail at the head, never try to read ~4 GB.
        #expect(throws: CBOR.DecodeError.sizeLimitExceeded) {
            try CBOR.decode(bytes("7a ffffffff"))
        }
    }

    @Test func badMapKeyAndUTF8() throws {
        #expect(throws: CBOR.DecodeError.badMapKey) {
            try CBOR.decode(bytes("a1 01 01"))  // map with uint key
        }
        #expect(throws: CBOR.DecodeError.badUTF8) {
            try CBOR.decode(bytes("62 c3 28"))  // invalid UTF-8 text
        }
    }

    /// Decoding is recursive, so unbounded nesting let a guest overflow
    /// the host daemon's stack one byte per level.
    @Test func deepNestingIsRefusedNotRecursedInto() {
        let deep = Data(repeating: 0x81, count: 10_000) + Data([0x00])  // [[[[…0…]]]]
        #expect(throws: CBOR.DecodeError.nestingTooDeep) { try CBOR.decode(deep) }
        let ok = Data(repeating: 0x81, count: CBOR.maxDepth) + Data([0x00])
        #expect((try? CBOR.decode(ok)) != nil)
    }

    @Test func oversizeEnvelopeThrowsInsteadOfTrapping() {
        let big = String(repeating: "x", count: OVMC.maxPayload)
        let env = Envelope(
            type: .clipboardRequest, correlationId: 1,
            body: .map([("op", .text("write")), ("text", .text(big))]))
        #expect(throws: EnvelopeError.self) { try EnvelopeCodec.encode(env) }
    }
}
