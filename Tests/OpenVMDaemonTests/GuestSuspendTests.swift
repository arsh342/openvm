// Tests for the suspend handshake.
import Darwin
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

/// The suspend handshake follows the GuestTimesyncTests probe pattern: a socket
/// pair plus a thread that plays the guest agent side. The host asks the guest
/// to quiesce before the host sleeps; the guest answers once it is flushed.
@Suite struct GuestSuspendTests {
    private func probe(reply: Envelope? = nil, timeout: Int = 1) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("Could not create guest-channel socket pair")
            return
        }
        let host = fds[0]
        let guest = fds[1]
        defer { close(host) }
        Thread.detachNewThread {
            defer { close(guest) }
            var decoder = FrameDecoder()
            guard let chunk = UnixSocket.readChunk(fd: guest), !chunk.isEmpty,
                let frames = try? decoder.feed(chunk),
                let request = frames.first,
                let env = try? EnvelopeCodec.decode(request),
                env.type == .suspendRequest, env.correlationId == 16
            else { return }
            if let reply {
                try? UnixSocket.writeAll(fd: guest, EnvelopeCodec.encode(reply))
            }
        }
        try GuestChannel.suspend(fd: host, timeoutSeconds: timeout)
    }

    @Test func aQuiesceAckCompletesTheHandshake() throws {
        try probe(reply: Envelope(type: .suspendReply, correlationId: 16, body: .map([])))
    }

    @Test func anAgentErrorReplyFailsTheHandshake() {
        #expect(throws: GuestBootError.self) {
            try probe(
                reply: Envelope(
                    type: .suspendReply, correlationId: 16,
                    body: .map([("error", .text("flush denied"))])))
        }
    }

    @Test func silenceTimesOut() {
        #expect(throws: GuestBootError.self) {
            try probe()
        }
    }

    @Test func aWrongReplyTypeIsIgnoredUntilTimeout() {
        #expect(throws: GuestBootError.self) {
            try probe(reply: Envelope(type: .echoReply, correlationId: 16, body: .map([])))
        }
    }
}
