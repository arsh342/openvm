// VmRequest — one VM operation from a client, and the dispatch to its handler.
import Foundation
import OpenVMCore

nonisolated func argValue(_ entries: [(key: String, value: CBOR)], _ name: String) -> CBOR? {
    entries.first(where: { $0.key == name })?.value
}

/// What a handler needs from a request, and the two ways it can answer.
nonisolated struct VmRequest {
    let op: String
    let args: [(key: String, value: CBOR)]
    let env: Envelope

    func arg(_ name: String) -> CBOR? { argValue(args, name) }

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
        if let refusal = channelRefusal(phase: guest.phase, name: record.name) {
            throw GuestBootError.failure(refusal)
        }
        return guest
    }
}

nonisolated func vmOp(_ op: String, _ args: [(key: String, value: CBOR)], _ env: Envelope) -> Envelope {
    let r = VmRequest(op: op, args: args, env: env)
    // The ops that change a VM's life hold its slot, so two clients cannot boot it twice.
    // A stop is let through a boot: it is how a boot is cancelled.
    if slotOps.contains(op), case .text(let id)? = r.arg("id"), let record = try? registry.resolve(id) {
        switch slotDecision(op: op, holder: activity.current(record.uuid)) {
        case .passThrough:
            return run(op, r)
        case .busy(let holder):
            return r.fail("\(record.name) is busy: \(holder)")
        case .take:
            // begin() can still lose a race with another connection
            guard activity.begin(record.uuid, op) else {
                return r.fail("\(record.name) is busy: \(activity.current(record.uuid) ?? "another operation")")
            }
            defer { activity.end(record.uuid) }
            return run(op, r)
        }
    }
    return run(op, r)
}

private nonisolated func run(_ op: String, _ r: VmRequest) -> Envelope {
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
        case "host-info": return try hostInfoOp(r)
        case "windows-iso-check": return try windowsISOCheckOp(r)
        case "task-start": return try taskStartOp(r)
        case "task-status": return try taskStatusOp(r)
        case "task-cancel": return try taskCancelOp(r)
        case "stop-all":
            let stopped = OpenVMHost.stopAllBlocking()
            return r.ok([("message", .text("stopped \(stopped) guest\(stopped == 1 ? "" : "s")"))])
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
