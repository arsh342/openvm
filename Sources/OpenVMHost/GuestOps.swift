// GuestOps — operations answered by a running guest's agent.
import Foundation
import OpenVMCore

nonisolated func pingGuest(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let g = try r.liveGuest(record)
    try GuestChannel.ping(g)
    return r.ok([("message", .text("pong \(record.name)"))])
}

nonisolated func clipboardOp(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let g = try r.liveGuest(record)
    let value: String
    if r.op == "clipboard-write" {
        guard case .text(let text)? = r.arg("text") else { return r.fail("missing clipboard text") }
        value = try GuestChannel.clipboard(g, text: text)
    } else {
        value = try GuestChannel.clipboard(g, text: nil)
    }
    return r.ok([("text", .text(value)), ("message", .text("clipboard operation complete"))])
}

nonisolated func fileOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("id") else { return r.fail("missing id") }
    let expectedOp = String(r.op.dropFirst("file-".count))
    guard r.arg("op") == .text(expectedOp) else { return r.fail("file operation mismatch") }
    let record = try registry.resolve(id)
    let g = try r.liveGuest(record)
    if case .bytes(let data)? = r.arg("data"), data.count > 65_536 {
        return r.fail("file chunk exceeds 65536 bytes")
    }
    let body = r.bodyForGuest
    let reply = try GuestChannel.fileChunk(g, body: body)
    guard case .map(let result) = reply else { return r.fail("guest file reply was not a map") }
    return r.ok(result)
}

/// A guest installed before an op existed answers it with its "must be" list of known ops. Say what that
/// means, instead of showing a message about a list the person never saw.
nonisolated func oldToolsHint(forSend message: String) -> String {
    message.contains("drag op must be")
        ? "this guest's tools are too old for that; reinstall the guest tools (create a new VM, or update the agent)"
        : message
}

nonisolated func dragOp(_ r: VmRequest) throws -> Envelope {
    do {
        return try dragOpUnchecked(r)
    } catch let error as GuestBootError {
        guard case .text("send")? = r.arg("op"), case .failure(let message) = error else { throw error }
        throw GuestBootError.failure(oldToolsHint(forSend: message))
    }
}

private nonisolated func dragOpUnchecked(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let g = try r.liveGuest(record)
    let result: [(key: String, value: CBOR)]
    switch r.arg("op") {
    case .text("drop")?:
        guard case .array(let rows)? = r.arg("paths") else { return r.fail("drop needs paths") }
        var paths: [String] = []
        for case .text(let path) in rows { paths.append(path) }
        result = try startDrop(record, g, paths: paths)
    case .text("status")?:
        result = try dropStatus(record, g)
    case .text("send")?:
        let reply = try GuestChannel.drag(g, body: r.bodyForGuest)
        guard case .map(let fields) = reply else { return r.fail("guest drag reply was not a map") }
        guard record.bootMode == .windows else { result = fields; break }
        // The Windows helper runs in the background, like a drop; follow it to the end.
        var last = fields
        for _ in 0..<600 {
            Thread.sleep(forTimeInterval: 1)
            last = try dropStatus(record, g)
            if let status = DragDrop.status(.map(last)), status.done { break }
        }
        result = last
    default:
        let body = r.bodyForGuest
        let reply = try GuestChannel.drag(g, body: body)
        guard case .map(let fields) = reply else { return r.fail("guest drag reply was not a map") }
        result = fields
    }
    return r.ok(result)
}

nonisolated func printerOp(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let g = try r.liveGuest(record)
    let body = r.bodyForGuest
    let reply = try GuestChannel.printer(g, body: body)
    guard case .map(let result) = reply else { return r.fail("guest printer reply was not a map") }
    return r.ok(result)
}

nonisolated func audioOp(_ r: VmRequest) throws -> Envelope {
    // The consent check needs nothing from the guest, so it comes first: a client that has not
    // agreed to Test Mode is told that, not that the guest is not running.
    if case .text(let op)? = r.arg("op") {
        var consent: Bool?
        if case .bool(let yes)? = r.arg("testMode") { consent = yes }
        if let refusal = audioEnableRefusal(op: op, testMode: consent) { return r.fail(refusal) }
    }
    let record = try r.record()
    let g = try r.liveGuest(record)
    // testMode is the host's consent flag, not part of the guest's request.
    let body = CBOR.map(r.args.filter { $0.key != "id" && $0.key != "testMode" })
    let reply = try GuestChannel.audio(g, body: body)
    guard case .map(let result) = reply else { return r.fail("guest audio reply was not a map") }
    return r.ok(result + [("hostOutputRunning", .bool(HostAudio.outputIsRunning()))])
}

nonisolated func displayOp(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let g = try r.liveGuest(record)
    if r.arg("op") == .text("capture") {
        let reply = try GuestChannel.display(g, body: .map([("op", .text("capture"))]), timeoutSeconds: 30)
        guard case .map(let result) = reply else { return r.fail("guest display reply was not a map") }
        return r.ok(result)
    }
    guard case .uint(let width)? = r.arg("width"), case .uint(let height)? = r.arg("height"),
        GuestDisplay.validMode(width: width, height: height)
    else {
        return r.fail("display needs a width of 640-7680 and a height of 480-4320")
    }
    var scale: UInt64?
    if case .uint(let asked)? = r.arg("scale") {
        guard GuestDisplay.validScale(asked) else { return r.fail("display scale must be 1, 2 or 3") }
        scale = asked
    }
    try setGuestDisplay(g, width: width, height: height, scale: scale)
    displayModes.set(record.uuid, width: width, height: height, scale: scale)
    let shown = scale.map { " at \($0)x" } ?? ""
    return r.ok([("message", .text("display is \(width)x\(height)\(shown)"))])
}
