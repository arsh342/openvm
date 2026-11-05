// The message catalogue, and the envelope that carries each message in a frame.
import Foundation

/// The message type id space. Append-only: existing ids are never reassigned or re-cast;
/// new capabilities append. The authoritative table lives in docs/guest-protocol.md.
public nonisolated enum MessageType: UInt16, Sendable {
    case hello = 1  // → sent by the opener; carries identity + version
    case helloReply = 2  // ← accepted (or negotiated) version
    case echoRequest = 3  // conformance / liveness
    case echoReply = 4  // mirrors the request payload + correlation id
    case error = 5  // structured failure for a previous request, or for an unroutable frame
    case vmRequest = 6  // → daemon operation: body {op: text, args: {…}}
    case vmReply = 7  // ← daemon result: body {op: text, status: text, result: {…}}
    case clipboardRequest = 8  // → guest: {op: "read"|"write", text?: text}
    case clipboardReply = 9  // ← guest: {text?: text, error?: text}
    case fileRequest = 10  // → guest: bounded read/write chunk
    case fileReply = 11  // ← guest: next offset, data/eof or error
    case timesyncRequest = 12  // → guest: {epochMs: uint}; agent sets the host clock
    case timesyncReply = 13  // ← guest: {} on success or {error: text}
    case sharedRequest = 14  // → guest: {op: "mount"|"unmount", name, path, probe?} (virtio-fs tag "openvm")
    case sharedReply = 15  // ← guest: {content?: text, error?: text}
    case suspendRequest = 16  // → guest: {op: "quiesce"}; agent flushes before the host sleeps
    case suspendReply = 17  // ← guest: {} on success or {error: text}
    case dragRequest = 18  // → guest: {op: "enter"|"leave"|"drop"|"status", share?, items?}
    case dragReply = 19  // ← guest: {accepted, done?, placed?, bytes?, error?}
    case printerRequest = 20  // → guest: {op: "list"|"sync"|"jobs"|"fetch"|"done"|"test", ...}
    case printerReply = 21  // ← guest: {printers?, jobs?, data?, error?}
    case audioRequest = 22  // → guest: {op: "start"|"stop"|"status"}
    case audioReply = 23  // ← guest: {running: bool, error?: text}
    case displayRequest = 24  // → guest: {width: uint, height: uint, scale?: uint}
    case displayReply = 25  // ← guest: {width: uint, height: uint, error?: text}
}

extension Envelope {
    /// vmRequest: ask the daemon to perform an operation (`create|list|start|stop`).
    public nonisolated static func vmRequest(
        op: String, args: [(key: String, value: CBOR)] = [],
        correlationId: UInt64 = 1
    ) -> Envelope {
        .init(
            type: .vmRequest, correlationId: correlationId,
            body: .map([("op", .text(op)), ("args", .map(args))]))
    }

    /// vmReply: the daemon's answer, status "ok" or "error".
    public nonisolated static func vmReply(
        op: String, status: String,
        result: [(key: String, value: CBOR)] = [],
        correlationId: UInt64
    ) -> Envelope {
        .init(
            type: .vmReply, correlationId: correlationId,
            body: .map([("op", .text(op)), ("status", .text(status)), ("result", .map(result))]))
    }
}

/// Error numbers for `error` frames. Fixed set, documented in docs/guest-protocol.md.
public nonisolated enum ErrNo: UInt64, Sendable {
    case unknownType = 1  // peer sent a type this side does not know
    case badPayload = 2  // CBOR did not decode to the catalogue's shape
    case unsupportedVersion = 3  // hello asked for a version we do not speak
}

/// One catalogued message on the channel: the frame plus its semantics.
/// The correlation id travels inside the CBOR map under the key "id"; the frame
/// header stays structural only.
public nonisolated struct Envelope: Equatable, Sendable {
    public var type: MessageType
    public var correlationId: UInt64
    public var body: CBOR  // always a CBOR map ("id" is spliced in/out by the codec)

    public init(type: MessageType, correlationId: UInt64, body: CBOR = .map([])) {
        self.type = type
        self.correlationId = correlationId
        self.body = body
    }

    /// The first message on a connection.
    public nonisolated static func hello(
        product: String, version: UInt16 = OVMC.currentVersion, correlationId: UInt64 = 1
    ) -> Envelope {
        .init(
            type: .hello, correlationId: correlationId,
            body: .map([("product", .text(product)), ("version", .uint(UInt64(version)))]))
    }

    /// The answer to `hello`.
    public nonisolated static func helloReply(
        accepted: Bool, version: UInt16 = OVMC.currentVersion, correlationId: UInt64
    ) -> Envelope {
        .init(
            type: .helloReply, correlationId: correlationId,
            body: .map([("accepted", .bool(accepted)), ("version", .uint(UInt64(version)))]))
    }

    /// An error reply to the given correlation id.
    public nonisolated static func error(_ errno: ErrNo, message: String, correlationId: UInt64 = 0)
        -> Envelope
    {
        .init(
            type: .error, correlationId: correlationId,
            body: .map([("errno", .uint(errno.rawValue)), ("message", .text(message))]))
    }
}

/// Why a frame could not become an envelope.
public nonisolated enum EnvelopeError: Error, Equatable, Sendable {
    case unknownType(UInt16)  // frame type not in the catalogue
    case bodyNotAMap
    case missingCorrelationId
    case payloadTooLarge(Int)  // encoded body exceeds OVMC.maxPayload
}

/// Converts between envelopes and frames.
public nonisolated enum EnvelopeCodec {
    /// Envelope → full wire bytes (frame with the CBOR map body, "id" spliced in).
    public nonisolated static func encode(_ e: Envelope) throws -> Data {
        var entries: [(key: String, value: CBOR)] = []
        if case .map(let b) = e.body { entries = b }
        entries.append(("id", .uint(e.correlationId)))
        let payload = CBOR.map(entries).encoded()
        // Frame.init traps on an oversize payload; an envelope built from
        // caller data (clipboard text, a file chunk) must fail as an error.
        guard payload.count <= OVMC.maxPayload else { throw EnvelopeError.payloadTooLarge(payload.count) }
        return Frame(type: e.type.rawValue, payload: payload).encoded()
    }

    /// Wire frame → Envelope. Unknown types raise (the caller answers with `.error(.unknownType)`).
    public nonisolated static func decode(_ f: Frame) throws -> Envelope {
        guard let mt = MessageType(rawValue: f.type) else { throw EnvelopeError.unknownType(f.type) }
        let body = try CBOR.decode(f.payload)
        guard case .map(let entries) = body else { throw EnvelopeError.bodyNotAMap }
        guard let id = entries.first(where: { $0.key == "id" }),
            case .uint(let cid) = id.value
        else { throw EnvelopeError.missingCorrelationId }
        return Envelope(
            type: mt, correlationId: cid,
            body: .map(entries.filter { $0.key != "id" }))
    }
}
