// DaemonClient — one request to openvmd over its socket, and its reply.
import Foundation
import OpenVMCore

nonisolated enum CLIError: Error, CustomStringConvertible {
    case remote(String)
    case protocolFailure(String)
    var description: String {
        switch self {
        case .remote(let message), .protocolFailure(let message): return message
        }
    }
}

let home =
    ProcessInfo.processInfo.environment["OPENVM_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm")
let sockPath = home.appendingPathComponent("openvmd.sock").path

func daemonRequest(_ op: String, args: [(key: String, value: CBOR)]) throws -> Envelope {
    let fd = try UnixSocket.connect(path: sockPath)
    defer { close(fd) }
    let request = Envelope.vmRequest(op: op, args: args)
    try UnixSocket.writeAll(fd: fd, EnvelopeCodec.encode(request))
    var decoder = FrameDecoder()
    while true {
        var chunk = Data(count: 4096)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
        guard n > 0 else { throw CLIError.protocolFailure("daemon closed before replying to \(op)") }
        let frames = try decoder.feed(chunk.prefix(n))
        for frame in frames {
            let reply = try EnvelopeCodec.decode(frame)
            guard reply.type == .vmReply else { continue }
            guard reply.correlationId == request.correlationId else {
                throw CLIError.protocolFailure("daemon reply correlation id did not match")
            }
            return reply
        }
    }
}

func resultFields(_ reply: Envelope) throws -> [(key: String, value: CBOR)] {
    guard case .map(let fields) = reply.body,
        case .text("ok")? = fields.first(where: { $0.key == "status" })?.value,
        case .map(let result)? = fields.first(where: { $0.key == "result" })?.value
    else {
        if case .map(let fields) = reply.body,
            case .map(let result)? = fields.first(where: { $0.key == "result" })?.value,
            case .text(let message)? = result.first(where: { $0.key == "message" })?.value
        {
            throw CLIError.remote(message)
        }
        throw CLIError.protocolFailure("daemon returned a malformed vmReply")
    }
    return result
}

func field(_ fields: [(key: String, value: CBOR)], _ key: String) -> CBOR? {
    fields.first(where: { $0.key == key })?.value
}
