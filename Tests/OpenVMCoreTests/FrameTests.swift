// Tests for the frame codec.
import Foundation
import Testing

@testable import OpenVMCore

private func bytes(_ hex: String) -> Data {
    Data(hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! })
}

@Suite struct FrameTests {

    // Golden wire bytes for EnvelopeCodec.encode(.hello(product: "openVM")):
    // magic "OVMC" | v1 | type 1 (hello) | flags 0 | len 29 | CBOR map {product,version,id}
    private let goldenHello = """
        4F 56 4D 43 00 01 00 01 00 00 00 00 00 1D
        A3 67 70 72 6F 64 75 63 74 66 6F 70 65 6E 56 4D
        67 76 65 72 73 69 6F 6E 01 62 69 64 01
        """

    @Test func goldenHelloFrame() throws {
        let wire = try EnvelopeCodec.encode(.hello(product: "openVM"))
        #expect(wire == bytes(goldenHello))
    }

    @Test func goldenHelloDecodes() throws {
        var dec = FrameDecoder()
        let frames = try dec.feed(bytes(goldenHello))
        #expect(frames.count == 1)
        let f = try #require(frames.first)
        #expect(f.version == 1)
        #expect(f.type == 1)
        #expect(f.flags == 0)
        let env = try EnvelopeCodec.decode(f)
        #expect(env.type == .hello)
        #expect(env.correlationId == 1)
        #expect(env.body == .map([("product", .text("openVM")), ("version", .uint(1))]))
    }

    @Test func roundTrip() throws {
        let f = Frame(type: .max, payload: Data("anything".utf8))
        var dec = FrameDecoder()
        let frames = try dec.feed(f.encoded())
        #expect(frames == [f])
    }

    @Test func streamingFeedKeepsPartialFrames() throws {
        let f = Frame(type: UInt16(9), payload: Data("body".utf8))
        let wire = f.encoded()
        var dec = FrameDecoder()
        #expect(try dec.feed(wire.prefix(10)) == [])  // partial header+payload
        #expect(try dec.feed(wire.dropFirst(10)) == [f])  // completion
        #expect(try dec.feed(Data()) == [])  // no trailing junk invented
    }

    @Test func badMagic() {
        var wire = Frame(type: 3, payload: Data("x".utf8)).encoded()
        wire[0] = 0x00
        #expect(throws: FrameError.badMagic) {
            var d = FrameDecoder()
            try d.feed(wire)
        }
    }

    @Test func unsupportedVersion() throws {
        let f = Frame(version: 2, type: 1, payload: Data("x".utf8))
        #expect(throws: FrameError.unsupportedVersion(2)) {
            var d = FrameDecoder()
            try d.feed(f.encoded())
        }
    }

    @Test func reservedFlags() throws {
        let f = Frame(type: 1, flags: 1, payload: Data("x".utf8))
        #expect(throws: FrameError.reservedFlags(1)) {
            var d = FrameDecoder()
            try d.feed(f.encoded())
        }
    }

    @Test func oversizeLength() {
        // length field = 0x00200000 > maxPayload, header hand-built (Frame init would refuse)
        let header = bytes("4F 56 4D 43 00 01 00 09 00 00 00 20 00 00")
        #expect(throws: FrameError.oversize(0x0020_0000)) {
            var d = FrameDecoder()
            try d.feed(header)
        }
    }

    @Test func errorClearsBufferAndDecoderStaysUsable() throws {
        var dec = FrameDecoder()
        try dec.feed(Data([0x4F, 0x56]))  // partial magic, fine
        #expect(throws: FrameError.unsupportedVersion(7)) {
            try dec.feed(bytes("4D 43 00 07 00 01 00 00 00 00 00 00"))
        }
        #expect(try dec.feed(Frame(type: 5).encoded()) != [])  // no poisoned state
    }
}
