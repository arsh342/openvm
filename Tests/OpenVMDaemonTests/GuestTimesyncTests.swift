// Tests for the clock push.
import Darwin
import Foundation
import OpenVMCore
import Testing

@testable import openvmd

/// The timesync channel loop follows the GuestReadinessTests probe pattern:
/// a socket pair plus a thread that plays the guest agent side.
@Suite struct GuestTimesyncTests {
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
                env.type == .timesyncRequest, env.correlationId == 12
            else { return }
            if let reply {
                try? UnixSocket.writeAll(fd: guest, EnvelopeCodec.encode(reply))
            }
        }
        try GuestChannel.timesync(fd: host, timeoutSeconds: timeout)
    }

    @Test func anAgentClockAckCompletesTheSync() throws {
        try probe(reply: Envelope(type: .timesyncReply, correlationId: 12, body: .map([])))
    }

    @Test func anAgentErrorReplyFailsTheSync() {
        #expect(throws: GuestBootError.self) {
            try probe(
                reply: Envelope(
                    type: .timesyncReply, correlationId: 12,
                    body: .map([("error", .text("clock denied"))])))
        }
    }

    @Test func silenceTimesOut() {
        #expect(throws: GuestBootError.self) {
            try probe()
        }
    }

    @Test func aWrongReplyTypeIsIgnoredUntilTimeout() {
        #expect(throws: GuestBootError.self) {
            try probe(reply: Envelope(type: .echoReply, correlationId: 12, body: .map([])))
        }
    }

    /// The VZ socket connect callback is delivered on the main queue, so a
    /// blocking exchange must not hold the main actor: the boot path once
    /// deadlocked exactly that way (the timesync connect never completed).
    @Test @MainActor func aBlockingExchangeLeavesTheMainActorFree() async throws {
        let flag = Flag()
        let work = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            flag.set()
        }
        let value = try await GuestChannel.offMainActor {
            Thread.sleep(forTimeInterval: 0.4)
            return 42
        }
        #expect(value == 42)
        #expect(flag.get(), "the main actor must keep running while a channel exchange blocks")
        await work.value
    }

    /// Minimal thread-safe flag for the main-actor liveness probe.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
