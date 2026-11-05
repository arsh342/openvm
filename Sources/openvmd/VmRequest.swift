// VmRequest — one VM operation from a client, and the dispatch to its handler.
import Foundation
import OpenVMCore

nonisolated func arg(_ entries: [(key: String, value: CBOR)], _ name: String) -> CBOR? {
    entries.first(where: { $0.key == name })?.value
}

/// What a handler needs from a request, and the two ways it can answer.
nonisolated struct VmRequest {
    let op: String
    let args: [(key: String, value: CBOR)]
    let env: Envelope

    func arg(_ name: String) -> CBOR? { openvmd.arg(args, name) }

    /// The arguments, as the guest agent takes them.
    var bodyForGuest: CBOR { .map(args.filter { $0.key != "id" }) }

    func ok(_ result: [(key: String, value: CBOR)]) -> Envelope {
        .vmReply(op: op, status: "ok", result: result, correlationId: env.correlationId)
    }

    func fail(_ message: String) -> Envelope {
        .vmReply(
            op: op, status: "error", result: [("message", .text(message))],
            correlationId: env.correlationId)
    }

    /// The VM this request names.
    func record() throws -> VmRecord {
        guard case .text(let id)? = arg("id") else { throw GuestBootError.failure("missing id") }
        return try registry.resolve(id)
    }

    func liveGuest(_ record: VmRecord) throws -> LiveGuest {
        guard let guest = liveVMs.peek(record.uuid) else {
            throw GuestBootError.failure("no live channel for \(record.name) (was the daemon restarted?)")
        }
        return guest
    }
}

nonisolated func vmOp(_ op: String, _ args: [(key: String, value: CBOR)], _ env: Envelope) -> Envelope {
    let r = VmRequest(op: op, args: args, env: env)
    do {
        switch op {
        case "create": return try createVm(r)
        case "list": return try listVms(r)
        case "info": return try vmInfo(r)
        case "delete": return try deleteVm(r)
        case "start": return try startVm(r)
        case "stop": return try stopVm(r)
        case "suspend": return try suspendVm(r)
        case "resume": return try resumeVm(r)
        case "set": return try setVm(r)
        case "share-add": return try addShare(r)
        case "share-remove": return try removeShare(r)
        case "share-list": return try listShares(r)
        case "ping": return try pingGuest(r)
        case "clipboard-read", "clipboard-write": return try clipboardOp(r)
        case "file-read", "file-write", "file-abort": return try fileOp(r)
        case "drag": return try dragOp(r)
        case "printer": return try printerOp(r)
        case "audio": return try audioOp(r)
        case "display": return try displayOp(r)
        default:
            return r.fail("unknown op \(op)")
        }
    } catch let e as GuestBootError {
        if case .failure(let m) = e { return r.fail(m) }
        return r.fail(String(describing: e))
    } catch let e as VmRegistryError {
        return r.fail(String(describing: e))
    } catch {
        return r.fail(String(describing: error))
    }
}
