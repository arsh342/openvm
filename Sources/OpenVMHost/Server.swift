// Server — the daemon's socket: one client at a time, one frame at a time.
import Foundation
import OpenVMCore

nonisolated func listenerLoop(fd: Int32) {
    while true {
        let client = UnixSocket.acceptOne(fd: fd)
        guard client >= 0 else { continue }
        serve(client)
        close(client)
    }
}

nonisolated func send(_ fd: Int32, _ env: Envelope) {
    // write failures surface in the read loop as EOF/reset and end the session
    try? UnixSocket.writeAll(fd: fd, EnvelopeCodec.encode(env))
}

nonisolated func serve(_ fd: Int32) {
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
                    send(fd, vmOp(op, args, env))
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
