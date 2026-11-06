// Clients are served concurrently: one VM's long boot must not stop another client's ops.
import Darwin
import Foundation
@testable import OpenVMCore
import Testing

@testable import OpenVMHost

struct ConcurrencyTests {
    @Test func secondStartIsRefusedAsBusy() {
        let table = ActivityTable()
        #expect(table.begin("vm-1", "start"))
        #expect(!table.begin("vm-1", "stop"))
        #expect(table.current("vm-1") == "start")
        table.end("vm-1")
        #expect(table.current("vm-1") == nil)
        #expect(table.begin("vm-1", "stop"))
    }

    @Test func differentVmsDoNotShareASlot() {
        let table = ActivityTable()
        #expect(table.begin("a", "start"))
        #expect(table.begin("b", "start"))
    }

    @Test func installAndDropFlagsAppearInRows() {
        let record = VmRecord(
            uuid: "uuid-flags-row", name: "flags", state: .stopped, cpus: 2, memoryMB: 1024,
            diskPath: nil, timezone: nil, shares: nil, bootMode: .windows,
            variableStorePath: nil, installMediaPath: nil, machineIdentifier: nil,
            createdAt: "2026-11-06T00:00:00Z")
        #expect(!vmRow(record).contains { $0.key == "installing" })
        installs.begin(record.uuid)
        defer { installs.end(record.uuid) }
        #expect(vmRow(record).contains { $0.key == "installing" && $0.value == .bool(true) })
    }

    @Test func activityAppearsInRows() {
        let record = VmRecord(
            uuid: "uuid-activity-row", name: "row", state: .stopped, cpus: 2, memoryMB: 1024,
            diskPath: nil, timezone: "Europe/Berlin", shares: nil, bootMode: .windows,
            variableStorePath: nil, installMediaPath: nil, machineIdentifier: nil,
            createdAt: "2026-11-06T00:00:00Z")
        #expect(!vmRow(record).contains { $0.key == "activity" })
        #expect(activity.begin(record.uuid, "start"))
        defer { activity.end(record.uuid) }
        let row = vmRow(record)
        #expect(row.contains { $0.key == "activity" && $0.value == .text("start") })
        #expect(row.contains { $0.key == "bootMode" && $0.value == .text("windows") })
        #expect(row.contains { $0.key == "timezone" && $0.value == .text("Europe/Berlin") })
    }

    /// Two real connections over socketpairs: one is stuck inside a slow op, and the
    /// other still gets its `list` answered.
    @Test func listAnswersWhileAnotherConnectionIsBusy() throws {
        let release = DispatchSemaphore(value: 0)
        let dispatch: @Sendable (String, [(key: String, value: CBOR)], Envelope) -> Envelope = { op, _, env in
            if op == "slow" { release.wait() }
            return .vmReply(op: op, status: "ok", result: [], correlationId: env.correlationId)
        }
        var a: [Int32] = [0, 0], b: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &a) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &b) == 0)
        for end in [a[1], b[1]] {
            Thread.detachNewThread {
                serve(end, dispatch: dispatch)
                close(end)
            }
        }
        defer {
            release.signal()
            close(a[0])
            close(b[0])
        }
        try UnixSocket.writeAll(fd: a[0], EnvelopeCodec.encode(.vmRequest(op: "slow", correlationId: 7)))
        try UnixSocket.writeAll(fd: b[0], EnvelopeCodec.encode(.vmRequest(op: "list", correlationId: 9)))

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(b[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var decoder = FrameDecoder()
        var reply: Envelope?
        while reply == nil {
            guard let chunk = UnixSocket.readChunk(fd: b[0]), !chunk.isEmpty else { break }
            for frame in try decoder.feed(chunk) { reply = try EnvelopeCodec.decode(frame) }
        }
        #expect(reply?.correlationId == 9)
    }
}

extension ConcurrencyTests {
    /// A client that leaves while its reply is being written must not take the host
    /// (and every VM in it) down with SIGPIPE.
    @Test func replyToAClosedClientDoesNotKillTheHost() throws {
        let proceed = DispatchSemaphore(value: 0)
        let served = DispatchSemaphore(value: 0)
        let dispatch: @Sendable (String, [(key: String, value: CBOR)], Envelope) -> Envelope = { op, _, env in
            proceed.wait()
            return .vmReply(op: op, status: "ok", result: [], correlationId: env.correlationId)
        }
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let server = pair[1]
        Thread.detachNewThread {
            serve(server, dispatch: dispatch)
            close(server)
            served.signal()
        }
        try UnixSocket.writeAll(fd: pair[0], EnvelopeCodec.encode(.vmRequest(op: "list", correlationId: 1)))
        close(pair[0])  // gone before the reply is written
        proceed.signal()
        #expect(served.wait(timeout: .now() + 3) == .success)
    }
}

extension ConcurrencyTests {
    /// `stop-all` with nothing live is not an error: it is what quitting an idle app does.
    @Test func stopAllWithNothingLiveSucceeds() {
        let reply = vmOp("stop-all", [], Envelope(type: .vmRequest, correlationId: 5))
        guard case .map(let body) = reply.body else {
            Issue.record("reply was not a map")
            return
        }
        #expect(body.contains { $0.key == "status" && $0.value == .text("ok") })
        #expect(reply.correlationId == 5)
    }
}
