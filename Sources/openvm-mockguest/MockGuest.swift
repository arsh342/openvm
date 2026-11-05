// A guest stand-in that speaks OVMC over stdin and stdout, for tests and conformance.
import Foundation
import OpenVMCore

/// The mock guest: speaks OVMC over stdin/stdout with no hypervisor, so everything above
/// the channel runs without a VM (CI, scripts, tests). Behaviour per docs/guest-protocol.md:
///   HELLO        → HELLO_REPLY(accepted: true) when the peer speaks our version
///   ECHO_REQUEST → ECHO_REPLY (same body, same correlation id)
///   other        → ERROR(.unknownType)
/// Unparseable or invalid frames are never answered: the decoder throws and the guest
/// exits nonzero (per guest-protocol.md, unparseable → the peer stops the connection).
final class MockGuest {
    private var decoder = FrameDecoder()

    /// Returns exit status. Reads stdin to EOF, writes replies as frames come complete.
    func run() -> Int {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        while true {
            let chunk = stdin.readData(ofLength: 1)
            if chunk.isEmpty { break }
            do {
                let out = try feed(chunk)
                if !out.isEmpty { stdout.write(out) }
            } catch { return 1 }  // invalid or unparseable input: no reply, exit 1
        }
        return 0
    }

    private func feed(_ chunk: Data) throws -> Data {
        var out = Data()
        for f in try decoder.feed(chunk) { out += try EnvelopeCodec.encode(respond(to: f)) }
        return out
    }

    private func respond(to f: Frame) throws -> Envelope {
        guard let e = try? EnvelopeCodec.decode(f) else {
            return .error(.badPayload, message: "frame body is not a catalogued message")
        }
        switch e.type {
        case .hello:
            if case .map(let entries) = e.body,
                let v = entries.first(where: { $0.key == "version" }),
                case .uint(UInt64(OVMC.currentVersion)) = v.value
            {
                return .helloReply(accepted: true, correlationId: e.correlationId)
            }
            return .error(
                .unsupportedVersion, message: "only version 1 is spoken", correlationId: e.correlationId)
        case .echoRequest:
            return Envelope(type: .echoReply, correlationId: e.correlationId, body: e.body)
        case .vmRequest:
            // The mock guest hosts no VM ops; the daemon does
            return .error(
                .unknownType, message: "mock guest: vmRequest is not supported",
                correlationId: e.correlationId)
        case .clipboardRequest:
            return .error(
                .unknownType, message: "mock guest does not implement clipboard",
                correlationId: e.correlationId)
        case .fileRequest:
            return .error(
                .unknownType, message: "mock guest does not implement file transfer",
                correlationId: e.correlationId)
        case .timesyncRequest:
            // a clock value the mock cannot meaningfully apply; refuse, don't fake
            return .error(
                .unknownType, message: "mock guest does not implement timesync",
                correlationId: e.correlationId)
        case .sharedRequest:
            // the mock guest has no filesystem to share; refuse, don't fake
            return .error(
                .unknownType, message: "mock guest does not implement shared folders",
                correlationId: e.correlationId)
        case .suspendRequest:
            // the mock guest has nothing to flush; refuse, don't fake
            return .error(
                .unknownType, message: "mock guest does not implement suspend handshake",
                correlationId: e.correlationId)
        case .dragRequest:
            return .error(
                .unknownType, message: "mock guest does not implement drag and drop",
                correlationId: e.correlationId)
        case .printerRequest:
            return .error(
                .unknownType, message: "mock guest does not implement printers",
                correlationId: e.correlationId)
        case .audioRequest:
            return .error(
                .unknownType, message: "mock guest does not implement audio",
                correlationId: e.correlationId)
        case .displayRequest:
            return .error(
                .unknownType, message: "mock guest does not implement display modeset",
                correlationId: e.correlationId)
        case .error, .echoReply, .helloReply, .vmReply, .clipboardReply, .fileReply, .timesyncReply,
            .sharedReply, .suspendReply, .dragReply, .printerReply, .audioReply, .displayReply:
            return .error(
                .unknownType, message: "only the opener drives; this side answers",
                correlationId: e.correlationId)
        }
    }
}

// Entry point
let exitStatus = MockGuest().run()
exit(Int32(exitStatus))
