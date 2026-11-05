// Tests for the message envelope.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct EnvelopeTests {

    @Test func clipboardMessageIDsAreAppendOnly() {
        #expect(MessageType.vmReply.rawValue == 7)
        #expect(MessageType.clipboardRequest.rawValue == 8)
        #expect(MessageType.clipboardReply.rawValue == 9)
    }

    @Test func clipboardPayloadsRoundTrip() throws {
        let request = Envelope(
            type: .clipboardRequest, correlationId: 8,
            body: .map([("op", .text("write")), ("text", .text("hello 🌱"))]))
        let wire = try EnvelopeCodec.encode(request)
        var decoder = FrameDecoder()
        let frame = try #require(decoder.feed(wire).first)
        #expect(try EnvelopeCodec.decode(frame) == request)

        let reply = Envelope(
            type: .clipboardReply, correlationId: 8,
            body: .map([("text", .text("from guest"))]))
        let replyWire = try EnvelopeCodec.encode(reply)
        var replyDecoder = FrameDecoder()
        let replyFrame = try #require(replyDecoder.feed(replyWire).first)
        #expect(try EnvelopeCodec.decode(replyFrame) == reply)
    }

    @Test func fileChunkPayloadRoundTrips() throws {
        let request = Envelope(
            type: .fileRequest, correlationId: 10,
            body: .map([
                ("op", .text("write")),
                ("name", .text("sample.bin")),
                ("transferId", .text("transfer-1")),
                ("offset", .uint(65_536)),
                ("data", .bytes(Data([0, 1, 2, 255]))),
                ("eof", .bool(false)),
            ]))
        let wire = try EnvelopeCodec.encode(request)
        var decoder = FrameDecoder()
        let frame = try #require(decoder.feed(wire).first)
        #expect(try EnvelopeCodec.decode(frame) == request)
        #expect(MessageType.fileRequest.rawValue == 10)
        #expect(MessageType.fileReply.rawValue == 11)
    }

    @Test func timesyncMessageIDsAreAppendOnly() {
        #expect(MessageType.timesyncRequest.rawValue == 12)
        #expect(MessageType.timesyncReply.rawValue == 13)
    }

    @Test func timesyncPayloadRoundTrips() throws {
        let request = Envelope(
            type: .timesyncRequest, correlationId: 12,
            body: .map([("epochMs", .uint(1_761_000_000_000))]))
        let wire = try EnvelopeCodec.encode(request)
        var decoder = FrameDecoder()
        let frame = try #require(decoder.feed(wire).first)
        #expect(try EnvelopeCodec.decode(frame) == request)

        let reply = Envelope(
            type: .timesyncReply, correlationId: 12,
            body: .map([("error", .text("clock denied"))]))
        let replyWire = try EnvelopeCodec.encode(reply)
        var replyDecoder = FrameDecoder()
        let replyFrame = try #require(replyDecoder.feed(replyWire).first)
        #expect(try EnvelopeCodec.decode(replyFrame) == reply)
    }

    @Test func sharedMessageIDsAreAppendOnly() {
        #expect(MessageType.sharedRequest.rawValue == 14)
        #expect(MessageType.sharedReply.rawValue == 15)
    }

    @Test func suspendMessageIDsAreAppendOnly() {
        #expect(MessageType.suspendRequest.rawValue == 16)
        #expect(MessageType.suspendReply.rawValue == 17)
    }

    @Test func suspendPayloadRoundTrips() throws {
        let request = Envelope(
            type: .suspendRequest, correlationId: 16,
            body: .map([("op", .text("quiesce"))]))
        let wire = try EnvelopeCodec.encode(request)
        var decoder = FrameDecoder()
        let frame = try #require(decoder.feed(wire).first)
        #expect(try EnvelopeCodec.decode(frame) == request)

        let reply = Envelope(
            type: .suspendReply, correlationId: 16,
            body: .map([("error", .text("flush denied"))]))
        let replyWire = try EnvelopeCodec.encode(reply)
        var replyDecoder = FrameDecoder()
        let replyFrame = try #require(replyDecoder.feed(replyWire).first)
        #expect(try EnvelopeCodec.decode(replyFrame) == reply)
    }

    @Test func sharedPayloadRoundTrips() throws {
        let request = Envelope(
            type: .sharedRequest, correlationId: 14,
            body: .map([
                ("op", .text("mount")), ("host", .text("192.168.64.1")),
                ("port", .uint(8125)), ("token", .text("abc123")),
                ("path", .text("/mnt/openvm")),
            ]))
        let wire = try EnvelopeCodec.encode(request)
        var decoder = FrameDecoder()
        let frame = try #require(decoder.feed(wire).first)
        #expect(try EnvelopeCodec.decode(frame) == request)

        let reply = Envelope(
            type: .sharedReply, correlationId: 14,
            body: .map([("content", .text("probe"))]))
        let replyWire = try EnvelopeCodec.encode(reply)
        var replyDecoder = FrameDecoder()
        let replyFrame = try #require(replyDecoder.feed(replyWire).first)
        #expect(try EnvelopeCodec.decode(replyFrame) == reply)
    }

    @Test func roundTrips() throws {
        let envelopes: [Envelope] = [
            .hello(product: "openvmctl"),
            .helloReply(accepted: true, correlationId: 1),
            .error(.badPayload, message: "payload was not a map"),
            Envelope(type: .echoRequest, correlationId: 7, body: .map([("ping", .uint(1))])),
        ]
        for e in envelopes {
            let f = try EnvelopeCodec.decode(
                Frame(type: e.type.rawValue, payload: try EnvelopeCodec.encode(e).dropFirst(OVMC.headerSize)))
            #expect(f == e)
        }
    }

    @Test func correlationIdTravelsInsideBody() throws {
        let wire = try EnvelopeCodec.encode(.error(.unknownType, message: "nope", correlationId: 42))
        var d = FrameDecoder()
        let f = try #require(d.feed(wire).first)
        let payload = try CBOR.decode(f.payload)
        guard case .map(let entries) = payload else {
            Issue.record("payload is not a map")
            return
        }
        guard case .uint(42)? = entries.last?.value else {  // "id" is the final key
            Issue.record("id is not the final key with uint value 42")
            return
        }
        #expect(entries.last?.key == "id")
        let env = try EnvelopeCodec.decode(f)
        #expect(env.correlationId == 42)
        if case .map(let body) = env.body { #expect(!body.contains { $0.key == "id" }) }  // id is stripped
    }

    @Test func unknownTypeIsRejected() throws {
        let f = Frame(type: 0x1234, payload: CBOR.map([("id", .uint(1))]).encoded())
        #expect(throws: EnvelopeError.unknownType(0x1234)) { try EnvelopeCodec.decode(f) }
    }

    @Test func bodyMustBeAMap() throws {
        let f = Frame(type: MessageType.echoRequest.rawValue, payload: CBOR.uint(5).encoded())
        #expect(throws: EnvelopeError.bodyNotAMap) { try EnvelopeCodec.decode(f) }
    }

    @Test func missingCorrelationId() throws {
        let f = Frame(
            type: MessageType.echoRequest.rawValue, payload: CBOR.map([("ping", .uint(1))]).encoded())
        #expect(throws: EnvelopeError.missingCorrelationId) { try EnvelopeCodec.decode(f) }

        let f2 = Frame(
            type: MessageType.echoRequest.rawValue, payload: CBOR.map([("id", .text("x"))]).encoded())
        #expect(throws: EnvelopeError.missingCorrelationId) { try EnvelopeCodec.decode(f2) }
    }
}
