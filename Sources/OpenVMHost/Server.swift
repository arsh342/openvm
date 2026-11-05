// Server — the host socket: every client on its own thread, one frame at a time per client.
import Foundation
import OpenVMCore

nonisolated func listenerLoop(fd: Int32) {
    while true {
        let client = UnixSocket.acceptOne(fd: fd)
        guard client >= 0 else { continue }
        // One thread per connection: a boot can take an hour, and the app and the CLI
        // are both clients. The VMs and the registry are what they share, and both lock.
        Thread.detachNewThread {
            serve(client)
            close(client)
        }
    }
}

nonisolated func send(_ fd: Int32, _ env: Envelope) {
    // write failures surface in the read loop as EOF/reset and end the session
    try? UnixSocket.writeAll(fd: fd, EnvelopeCodec.encode(env))
}

typealias VmDispatch = @Sendable (String, [(key: String, value: CBOR)], Envelope) -> Envelope

/// Serves one connection until it closes. `dispatch` is a parameter so a test can
/// stand in a slow handler.
nonisolated func serve(_ fd: Int32, dispatch: VmDispatch = vmOp) {
    UnixSocket.suppressSigpipe(fd: fd)
    var decoder = FrameDecoder()
    var buffer = Data()
    while true {
        if buffer.isEmpty {
            guard let more = UnixSocket.readChunk(fd: fd), !more.isEmpty else {
                return  // peer closed or read failed
            }
            buffer.append(more)
        }
        do {
            let frames = try decoder.feed(buffer)
            buffer.removeAll()
            for frame in frames {
                // A header-valid frame whose body does not decode is answered
                // with `error` (correlation id 0) and the session continues
                // (docs/guest-protocol.md receiver rule 5). Only a frame-rule
                // violation, thrown by the decoder above, ends the connection.
                let env: Envelope
                do {
                    env = try EnvelopeCodec.decode(frame)
                } catch EnvelopeError.unknownType(let t) {
                    send(fd, .error(.unknownType, message: "unknown message type \(t)"))
                    continue
                } catch {
                    send(fd, .error(.badPayload, message: "frame body is not a catalogued message"))
                    continue
                }
                switch env.type {
                case .hello:
                    // Accept every client: the socket's directory permissions are the access control.
                    send(
                        fd,
                        .helloReply(
                            accepted: true, version: OVMC.currentVersion,
                            correlationId: env.correlationId))
                case .echoRequest:
                    send(fd, Envelope(type: .echoReply, correlationId: env.correlationId, body: env.body))
                case .vmRequest:
                    let op: String
                    let args: [(key: String, value: CBOR)]
                    guard case .map(let entries) = env.body,
                        case .text(let o)? = entries.first(where: { $0.key == "op" })?.value,
                        case .map(let a)? = entries.first(where: { $0.key == "args" })?.value
                    else {
                        send(
                            fd,
                            .error(
                                .badPayload, message: "malformed vmRequest", correlationId: env.correlationId)
                        )
                        continue
                    }
                    op = o
                    args = a
                    send(fd, dispatch(op, args, env))
                case .helloReply, .echoReply, .vmReply, .clipboardRequest, .clipboardReply,
                    .fileRequest, .fileReply, .timesyncRequest, .timesyncReply,
                    .sharedRequest, .sharedReply, .suspendRequest, .suspendReply,
                    .dragRequest, .dragReply, .printerRequest, .printerReply,
                    .audioRequest, .audioReply, .displayRequest, .displayReply, .error:
                    break  // client→daemon replies have no meaning here
                }
            }
        } catch {
            return  // bad frame: drop the connection per docs/guest-protocol.md
        }
    }
}

nonisolated func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
