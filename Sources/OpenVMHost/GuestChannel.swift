// GuestChannel — the host end of the guest agent's channel. Every exchange is one
// fresh vsock connection, one request, and one matching reply or a deadline.
import Foundation
import OpenVMCore
import Virtualization

/// Host side of the dedicated OVMC channel. The
/// host is the opener: each ping connects to the guest agent's listener on
/// vsock port 52, sends one echoRequest and drains until the matching
/// echoReply or the deadline. The connection object owns the fd — it must
/// stay alive for the whole exchange.
nonisolated final class ConnBox: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var conn: VZVirtioSocketConnection?
    private var error = ""
    private var expired = false

    func complete(_ c: VZVirtioSocketConnection?, _ e: String) {
        lock.lock()
        if expired {
            lock.unlock()
            c?.close()
            return
        }
        conn = c
        error = e
        lock.unlock()
        sem.signal()
    }

    /// Returns a stable result and closes a connection that arrives after timeout.
    func wait(deadline: DispatchTime) -> (
        connection: VZVirtioSocketConnection?, error: String, timedOut: Bool
    ) {
        let signaled = sem.wait(timeout: deadline) == .success
        lock.lock()
        defer { lock.unlock() }
        if !signaled && conn == nil && error.isEmpty {
            expired = true
            return (nil, "", true)
        }
        let result = (conn, error, false)
        conn = nil
        return result
    }
}

nonisolated enum GuestChannel {
    static let port: UInt32 = 52

    /// One kind of request: its message types, its correlation id, and the name its
    /// errors go by.
    private struct Exchange {
        let request: MessageType
        let reply: MessageType
        let id: UInt64
        let name: String
    }

    /// Runs a blocking channel exchange off the main actor. The VZ connect
    /// callback is delivered on the main queue, so an exchange that waits for
    /// it must never hold the main actor — the boot path once deadlocked
    /// exactly that way (the connect never completed, the wait timed out).
    static func offMainActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try body() }.value
    }

    /// Keep the main dispatch queue free for VZ's connection callback while the
    /// blocking transport probe runs. Existing agents need not emit log markers.
    @MainActor
    static func responds(_ guest: LiveGuest) async -> Bool {
        do {
            try await offMainActor { try ping(guest, timeoutSeconds: 1) }
            return true
        } catch {
            return false
        }
    }

    /// Connects to the guest agent, and closes the connection when `use` returns.
    private static func withConnection<T>(_ g: LiveGuest, _ use: (Int32) throws -> T) throws -> T {
        guard g.hasAgent else { throw GuestBootError.failure("this guest has no openVM tools") }
        let box = ConnBox()
        Task { @MainActor in
            do {
                guard let device = g.vm.socketDevices.first as? VZVirtioSocketDevice else {
                    box.complete(nil, "vsock device missing after boot")
                    return
                }
                box.complete(try await device.connect(toPort: port), "")
            } catch {
                box.complete(nil, "channel connect failed: \(error)")
            }
        }
        let result = box.wait(deadline: .now() + .seconds(2))
        guard let conn = result.connection else {
            throw GuestBootError.failure(
                result.timedOut
                    ? "guest channel connect timed out (is the agent up?)"
                    : result.error)
        }
        defer { conn.close() }
        return try use(conn.fileDescriptor)
    }

    /// Sends one request and returns the body of its reply. An `error` in the reply
    /// is thrown, unless `acceptError` says the caller reads it.
    private static func exchange(
        _ kind: Exchange, body: CBOR, fd: Int32, timeoutSeconds: Double,
        acceptError: Bool = false
    ) throws -> CBOR {
        let request = Envelope(type: kind.request, correlationId: kind.id, body: body)
        try UnixSocket.writeAll(fd: fd, EnvelopeCodec.encode(request))

        var decoder = FrameDecoder()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var scratch = [UInt8](repeating: 0, count: 70 * 1024)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: 0x0001 /*POLLIN*/, revents: 0)
            guard poll(&pfd, 1, 250) > 0, pfd.revents & 0x0001 != 0 else { continue }
            let n = read(fd, &scratch, scratch.count)
            guard n > 0 else { throw GuestBootError.failure("guest closed the \(kind.name) channel") }
            for frame in try decoder.feed(Data(scratch[0..<n])) {
                let reply = try EnvelopeCodec.decode(frame)
                guard reply.correlationId == kind.id else { continue }
                if reply.type == .error, let message = text("message", in: reply.body) {
                    throw GuestBootError.failure("guest \(kind.name) failed: \(message)")
                }
                guard reply.type == kind.reply else { continue }
                if !acceptError, let message = text("error", in: reply.body) {
                    throw GuestBootError.failure("guest \(kind.name) failed: \(message)")
                }
                return reply.body
            }
        }
        throw GuestBootError.failure("guest \(kind.name) timed out")
    }

    private static func text(_ key: String, in body: CBOR) -> String? {
        guard case .map(let fields) = body,
            case .text(let value)? = fields.first(where: { $0.key == key })?.value
        else { return nil }
        return value
    }

    private static let echoKind = Exchange(request: .echoRequest, reply: .echoReply, id: 7, name: "echo")
    private static let clipboardKind = Exchange(
        request: .clipboardRequest, reply: .clipboardReply, id: 8, name: "clipboard")
    private static let fileKind = Exchange(
        request: .fileRequest, reply: .fileReply, id: 10, name: "file transfer")
    private static let timesyncKind = Exchange(
        request: .timesyncRequest, reply: .timesyncReply, id: 12, name: "timesync")
    private static let sharedKind = Exchange(
        request: .sharedRequest, reply: .sharedReply, id: 14, name: "share request")
    private static let suspendKind = Exchange(
        request: .suspendRequest, reply: .suspendReply, id: 16, name: "suspend handshake")
    private static let dragKind = Exchange(request: .dragRequest, reply: .dragReply, id: 18, name: "drag")
    private static let printerKind = Exchange(
        request: .printerRequest, reply: .printerReply, id: 20, name: "printer")
    private static let audioKind = Exchange(request: .audioRequest, reply: .audioReply, id: 22, name: "audio")
    private static let displayKind = Exchange(
        request: .displayRequest, reply: .displayReply, id: 24, name: "display")

    /// One echo round trip: the proof the agent is alive.
    static func ping(_ g: LiveGuest, timeoutSeconds: Int = 5) throws {
        try withConnection(g) { try echo(fd: $0, timeoutSeconds: timeoutSeconds) }
    }

    static func echo(fd: Int32, timeoutSeconds: Int = 5) throws {
        _ = try exchange(
            echoKind, body: .map([("ping", .text("hallo"))]), fd: fd,
            timeoutSeconds: Double(timeoutSeconds))
    }

    /// Reads guest clipboard text when `text` is nil; writes it otherwise.
    /// The session-aware clipboard backend is implemented by the guest agent.
    static func clipboard(_ g: LiveGuest, text written: String?) throws -> String {
        let body: CBOR =
            written.map { .map([("op", .text("write")), ("text", .text($0))]) }
            ?? .map([("op", .text("read"))])
        let reply = try withConnection(g) {
            try exchange(clipboardKind, body: body, fd: $0, timeoutSeconds: 5)
        }
        if written != nil { return "" }
        guard let value = text("text", in: reply) else {
            throw GuestBootError.failure("guest clipboard reply omitted text")
        }
        return value
    }

    /// Exchanges one bounded file chunk. The caller validates the transfer
    /// sequence and writes or consumes the returned bytes.
    static func fileChunk(_ g: LiveGuest, body: CBOR) throws -> CBOR {
        try withConnection(g) { try exchange(fileKind, body: body, fd: $0, timeoutSeconds: 15) }
    }

    /// Asks the guest to mount or unmount a shared folder. The body carries
    /// {op, name, path, probe?}, where `name` is the share's entry in the virtio-fs
    /// device (SharedFolders.name). The guest may load the virtiofs module and
    /// remount the tag first, so the deadline leaves room for that.
    static func shared(_ g: LiveGuest, body: CBOR) throws -> CBOR {
        try withConnection(g) { try exchange(sharedKind, body: body, fd: $0, timeoutSeconds: 40) }
    }

    /// Pushes the host wall clock into the guest. Called after the agent is known
    /// alive (boot and resume paths); call sites treat failure as non-fatal.
    /// `timezone` is an optional IANA zone the guest applies.
    static func timesync(_ g: LiveGuest, timeoutSeconds: Int = 5, timezone: String? = nil) throws {
        try withConnection(g) { try timesync(fd: $0, timeoutSeconds: timeoutSeconds, timezone: timezone) }
    }

    static func timesync(fd: Int32, timeoutSeconds: Int = 5, timezone: String? = nil) throws {
        var body: [(key: String, value: CBOR)] = [
            ("epochMs", .uint(UInt64(Date().timeIntervalSince1970 * 1_000)))
        ]
        if let timezone { body.append(("tz", .text(timezone))) }
        _ = try exchange(timesyncKind, body: .map(body), fd: fd, timeoutSeconds: Double(timeoutSeconds))
    }

    /// Ask the guest to quiesce before the host sleeps: the agent flushes its
    /// filesystem and answers, and only then does the host pause the VM.
    static func suspend(_ g: LiveGuest, timeoutSeconds: Int = 5, op: String = "quiesce") throws {
        try withConnection(g) { try suspend(fd: $0, timeoutSeconds: timeoutSeconds, op: op) }
    }

    static func suspend(fd: Int32, timeoutSeconds: Int = 5, op: String = "quiesce") throws {
        _ = try exchange(
            suspendKind, body: .map([("op", .text(op))]), fd: fd,
            timeoutSeconds: Double(timeoutSeconds))
    }

    /// Drag and drop. With `acceptError`, an `error` in the reply is returned, not
    /// thrown: a drop's status reports its failure that way.
    static func drag(_ g: LiveGuest, body: CBOR, timeoutSeconds: Int = 5, acceptError: Bool = false) throws
        -> CBOR
    {
        try withConnection(g) {
            try exchange(
                dragKind, body: body, fd: $0, timeoutSeconds: Double(timeoutSeconds), acceptError: acceptError
            )
        }
    }

    /// Publishes the host's printers, and collects finished jobs from the guest's
    /// spool (PrinterBridge.swift).
    static func printer(_ g: LiveGuest, body: CBOR, timeoutSeconds: Int = 10) throws -> CBOR {
        try withConnection(g) {
            try exchange(printerKind, body: body, fd: $0, timeoutSeconds: Double(timeoutSeconds))
        }
    }

    /// A Windows guest runs a script for every audio op, and enable and disable
    /// change the driver store.
    static func audio(_ g: LiveGuest, body: CBOR) throws -> CBOR {
        var seconds = 15.0
        if let op = text("op", in: body), op == "enable" || op == "disable" { seconds = 120 }
        return try withConnection(g) { try exchange(audioKind, body: body, fd: $0, timeoutSeconds: seconds) }
    }

    /// A display mode change, or a capture.
    static func display(_ g: LiveGuest, body: CBOR, timeoutSeconds: Int = 5) throws -> CBOR {
        try withConnection(g) {
            try exchange(displayKind, body: body, fd: $0, timeoutSeconds: Double(timeoutSeconds))
        }
    }
}
