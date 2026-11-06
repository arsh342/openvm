// The client shared by openvmctl and the app: one request, one reply, over a real socket.
import Darwin
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct DaemonClientTests {
    /// A one-shot server on a real Unix socket. `reply` gets the request and writes however it likes.
    private func serveOnce(_ reply: @escaping @Sendable (Int32, Envelope) throws -> Void) throws -> (
        path: String, cleanup: () -> Void
    ) {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("ovmc-\(UUID().uuidString.prefix(8))")
        let path = dir.appendingPathComponent("s.sock").path
        let listener = try UnixSocket.bindListen(path: path)
        Thread.detachNewThread {
            let client = UnixSocket.acceptOne(fd: listener)
            guard client >= 0 else { return }
            var decoder = FrameDecoder()
            while let chunk = UnixSocket.readChunk(fd: client), !chunk.isEmpty {
                if let frame = try? decoder.feed(chunk).first, let request = try? EnvelopeCodec.decode(frame) {
                    try? reply(client, request)
                    break
                }
            }
            close(client)
        }
        return (path, { close(listener); try? FileManager.default.removeItem(at: dir) })
    }

    @Test func replySplitAcrossReadsDecodes() throws {
        let server = try serveOnce { fd, request in
            let bytes = try EnvelopeCodec.encode(
                .vmReply(op: "list", status: "ok", result: [("message", .text("hello"))],
                         correlationId: request.correlationId))
            try UnixSocket.writeAll(fd: fd, bytes.prefix(7))
            usleep(50_000)
            try UnixSocket.writeAll(fd: fd, bytes.dropFirst(7))
        }
        defer { server.cleanup() }
        let reply = try DaemonClient(socket: server.path).request("list", args: [])
        let fields = try DaemonClient.resultFields(reply)
        #expect(DaemonClient.field(fields, "message") == .text("hello"))
    }

    @Test func correlationMismatchIsAnError() throws {
        let server = try serveOnce { fd, _ in
            try UnixSocket.writeAll(
                fd: fd, EnvelopeCodec.encode(.vmReply(op: "list", status: "ok", correlationId: 99)))
        }
        defer { server.cleanup() }
        #expect(throws: HostError.self) { try DaemonClient(socket: server.path).request("list", args: []) }
    }

    @Test func errorReplyThrowsItsMessage() throws {
        let server = try serveOnce { fd, request in
            try UnixSocket.writeAll(
                fd: fd,
                EnvelopeCodec.encode(
                    .vmReply(op: "start", status: "error", result: [("message", .text("w is busy: start"))],
                             correlationId: request.correlationId)))
        }
        defer { server.cleanup() }
        let reply = try DaemonClient(socket: server.path).request("start", args: [])
        #expect(throws: HostError.remote("w is busy: start")) { try DaemonClient.resultFields(reply) }
    }

    @Test func sendRunsOffTheMainThread() async throws {
        let server = try serveOnce { fd, request in
            try UnixSocket.writeAll(
                fd: fd, EnvelopeCodec.encode(.vmReply(op: "list", status: "ok", correlationId: request.correlationId)))
        }
        defer { server.cleanup() }
        let fields = try await DaemonClient(socket: server.path).send("list", [])
        #expect(fields.isEmpty)
    }

    @Test func missingHostIsReportedNotCrashed() async {
        let client = DaemonClient(socket: "/tmp/no-such-openvm-socket")
        await #expect(throws: (any Error).self) { try await client.send("list", []) }
    }
}

@Suite struct VmSummaryTests {
    private func row(_ extra: [(key: String, value: CBOR)] = []) -> CBOR {
        .map(
            [
                ("name", .text("win")), ("state", .text("running")), ("uuid", .text("u-1")),
                ("cpus", .uint(4)), ("memoryMB", .uint(8192)),
            ] + extra)
    }

    @Test func summaryDecodesRowsWithAndWithoutNewFields() {
        let old = VmSummary(row: row())
        #expect(old?.name == "win")
        #expect(old?.state == .running)
        #expect(old?.bootMode == .linux)  // an older host sends no bootMode
        #expect(old?.activity == nil)
        let new = VmSummary(
            row: row([
                ("bootMode", .text("windows")), ("activity", .text("start")), ("diskBytes", .uint(1 << 30)),
                ("timezone", .text("Europe/Berlin")),
            ]))
        #expect(new?.bootMode == .windows)
        #expect(new?.activity == "start")
        #expect(new?.diskBytes == 1 << 30)
        #expect(new?.timezone == "Europe/Berlin")
        #expect(new?.id == "u-1")
    }

    @Test func rowsMissingRequiredFieldsAreRejected() {
        #expect(VmSummary(row: .map([("name", .text("x"))])) == nil)
        #expect(VmSummary(row: .text("nope")) == nil)
        #expect(VmSummary(row: .map([("name", .text("x")), ("state", .text("sleeping")), ("uuid", .text("u"))])) == nil)
    }
}

extension VmSummaryTests {
    @Test func installingAndDroppingDefaultToFalseAndDecodeWhenSent() {
        let base: [(key: String, value: CBOR)] = [
            ("name", .text("w")), ("state", .text("stopped")), ("uuid", .text("u")),
        ]
        let old = VmSummary(row: .map(base))
        #expect(old?.installing == false)  // an older host sends neither field
        #expect(old?.dropping == false)
        let busy = VmSummary(row: .map(base + [("installing", .bool(true)), ("dropping", .bool(true))]))
        #expect(busy?.installing == true)
        #expect(busy?.dropping == true)
    }
}

extension VmSummaryTests {
    @Test func clipboardSyncDefaultsToOnAndDecodesWhenSent() {
        let base: [(key: String, value: CBOR)] = [
            ("name", .text("w")), ("state", .text("stopped")), ("uuid", .text("u")),
        ]
        #expect(VmSummary(row: .map(base))?.clipboardSync == true)  // an older host sends nothing
        #expect(VmSummary(row: .map(base + [("clipboardSync", .bool(false))]))?.clipboardSync == false)
    }
}

@Suite struct HostInfoDecodingTests {
    @Test func hostInfoDecodes() {
        let info = HostInfo(fields: [
            ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(500_000)),
            ("linuxReady", .bool(true)), ("hostWimlib", .bool(false)),
        ])
        #expect(info == HostInfo(maxCpus: 8, maxMemoryMB: 16384, freeDiskMB: 500_000, linuxReady: true, hostWimlib: false))
    }

    @Test func aReplyMissingTheLimitsIsRejected() {
        #expect(HostInfo(fields: [("linuxReady", .bool(true))]) == nil)
    }
}
