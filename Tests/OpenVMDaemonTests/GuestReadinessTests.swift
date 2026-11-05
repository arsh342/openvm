// Tests for the agent readiness check.
import Darwin
import Foundation
import OpenVMCore
import Testing

@testable import openvmd

@Suite struct GuestReadinessTests {
    private func probe(replyType: MessageType, correlationId: UInt64) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            Issue.record("Could not create guest-channel socket pair")
            return
        }
        let host = fds[0]
        let guest = fds[1]
        defer { close(host) }
        let reply = try EnvelopeCodec.encode(
            Envelope(type: replyType, correlationId: correlationId, body: .map([])))
        Thread.detachNewThread {
            defer { close(guest) }
            guard UnixSocket.readChunk(fd: guest) != nil else { return }
            try? UnixSocket.writeAll(fd: guest, reply)
        }
        try GuestChannel.echo(fd: host, timeoutSeconds: 1)
    }

    @Test func matchingGuestReplyConfirmsReadiness() throws {
        try probe(replyType: .echoReply, correlationId: 7)
    }

    @Test func unrelatedReplyDoesNotConfirmReadiness() {
        #expect(throws: GuestBootError.self) {
            try probe(replyType: .echoReply, correlationId: 99)
        }
    }

    @Test func wrongMessageTypeDoesNotConfirmReadiness() {
        #expect(throws: GuestBootError.self) {
            try probe(replyType: .helloReply, correlationId: 7)
        }
    }
}
