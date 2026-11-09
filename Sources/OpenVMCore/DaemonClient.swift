// DaemonClient — one request to the host over its socket, and its reply. Shared by
// openvmctl and the app, so both speak to the host the same way.
import Darwin
import Foundation

public nonisolated enum HostError: Error, Equatable, CustomStringConvertible {
    /// The host answered, and said no.
    case remote(String)
    /// The host answered with something that is not in the protocol.
    case protocolFailure(String)

    public var description: String {
        switch self {
        case .remote(let message), .protocolFailure(let message): return message
        }
    }
}

/// Anything that can put a request to the host. The app's models take this, so tests
/// can stand in for the host.
public protocol HostTransport: Sendable {
    func send(_ op: String, _ args: [(key: String, value: CBOR)]) async throws -> [(key: String, value: CBOR)]
}

extension HostTransport {
    /// Every VM the host knows, as the list shows them.
    public func listVMs() async throws -> [VmSummary] {
        let result = try await send("list", [])
        guard case .array(let rows)? = DaemonClient.field(result, "vms") else { return [] }
        return rows.compactMap(VmSummary.init(row:))
    }
}

public nonisolated struct DaemonClient: HostTransport {
    public let socket: String

    public init(socket: String = OVMPaths.socket) { self.socket = socket }

    /// One blocking request. The CLI calls this on its main thread; the app must not,
    /// because a long op would freeze its windows. The app uses `send`, which runs it
    /// off the main thread.
    public func request(_ op: String, args: [(key: String, value: CBOR)]) throws -> Envelope {
        let fd = try UnixSocket.connect(path: socket)
        defer { close(fd) }
        let request = Envelope.vmRequest(op: op, args: args)
        try UnixSocket.writeAll(fd: fd, EnvelopeCodec.encode(request))
        var decoder = FrameDecoder()
        while true {
            var chunk = Data(count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            guard n > 0 else { throw HostError.protocolFailure("the host closed before replying to \(op)") }
            for frame in try decoder.feed(chunk.prefix(n)) {
                let reply = try EnvelopeCodec.decode(frame)
                guard reply.type == .vmReply else { continue }
                guard reply.correlationId == request.correlationId else {
                    throw HostError.protocolFailure("the host's reply did not match the request")
                }
                return reply
            }
        }
    }

    public func send(_ op: String, _ args: [(key: String, value: CBOR)]) async throws -> [(
        key: String, value: CBOR
    )] {
        let client = self
        return try await Task.detached(priority: .userInitiated) {
            try Self.resultFields(try client.request(op, args: args))
        }.value
    }

    /// The `result` of an ok reply; throws the host's message for an error reply.
    public static func resultFields(_ reply: Envelope) throws -> [(key: String, value: CBOR)] {
        guard case .map(let fields) = reply.body else {
            throw HostError.protocolFailure("the host returned a malformed vmReply")
        }
        let result: [(key: String, value: CBOR)]
        if case .map(let r)? = fields.first(where: { $0.key == "result" })?.value { result = r } else { result = [] }
        guard case .text("ok")? = fields.first(where: { $0.key == "status" })?.value else {
            if case .text(let message)? = result.first(where: { $0.key == "message" })?.value {
                throw HostError.remote(message)
            }
            throw HostError.protocolFailure("the host returned a malformed vmReply")
        }
        return result
    }

    public static func field(_ fields: [(key: String, value: CBOR)], _ key: String) -> CBOR? {
        fields.first(where: { $0.key == key })?.value
    }
}
