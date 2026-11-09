// ShareOps — shared folders: mounting them in a guest, and the share operations.
import Foundation
import OpenVMCore

/// Guest-side mount path check: absolute, no "..", no empty components. The
/// agent repeats this check before it touches the guest filesystem.
nonisolated func validGuestPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.utf8.count <= 240, !path.contains("//") else { return false }
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
        guard !part.isEmpty, part != "..", part.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
    }
    return true
}

/// Point the live virtio-fs device at a share set. VZ objects belong to the
/// main queue; callers here run on the listener thread (or a detached task),
/// so the update hops to the main actor and waits.
nonisolated func applyShares(_ shares: [VmShare], of record: VmRecord, to g: LiveGuest) -> Bool {
    let drops = try? dropRoot(record.uuid, create: false)
    let outbox = try? outboxRoot(record.uuid, create: false)
    let wait = BootWaiter()
    Task { @MainActor in
        wait.complete(SharedFolders.apply(shares, drops: drops, outbox: outbox, to: g.vm) ? "" : "no virtio-fs device")
    }
    wait.wait()
    return wait.value == ""
}

/// Mount one shared folder in the guest. With `probe`, a file is written into
/// the shared directory first and read back through the mount, which proves the
/// round trip instead of trusting the mount command's exit status.
///
/// `shares` is the record's full share set, which the device must carry
/// before the guest can see the new entry.
///
/// Returns where the guest says the share is, when it says (the Windows agent
/// does: every share is a directory of its virtio-fs drive).
@discardableResult
nonisolated func mountShare(
    _ record: VmRecord, _ share: VmShare, probe: Bool,
    allShares: [VmShare]
) throws -> String? {
    guard let g = liveVMs.peek(record.uuid) else {
        throw GuestBootError.failure("no live channel for \(record.name)")
    }
    guard applyShares(allShares, of: record, to: g) else {
        throw GuestBootError.failure(
            "\(record.name) has no virtio-fs device (started before shared folders moved to virtio-fs?); restart it"
        )
    }
    var body: [(key: String, value: CBOR)] = [
        ("op", .text("mount")),
        ("name", .text(SharedFolders.name(for: share.hostPath))),
        ("path", .text(share.guestPath)),
    ]
    var probeName: String?
    var probeContent: String?
    if probe {
        let name = ".openvm-probe-\(UUID().uuidString.lowercased())"
        let content = "openvm-share-probe-\(UUID().uuidString)"
        try Data(content.utf8).write(to: URL(fileURLWithPath: share.hostPath).appendingPathComponent(name))
        probeName = name
        probeContent = content
        body.append(("probe", .text(name)))
    }
    defer {
        if let probeName {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: share.hostPath).appendingPathComponent(probeName))
        }
    }
    let reply = try GuestChannel.shared(g, body: CBOR.map(body))
    guard case .map(let entries) = reply else {
        throw GuestBootError.failure("guest share reply was not a map")
    }
    if case .text(let message)? = entries.first(where: { $0.key == "error" })?.value {
        throw GuestBootError.failure("guest mount failed: \(message)")
    }
    if let probeContent {
        // The proof has to be there: a reply without the probe content means
        // the guest never read the file back through the mount.
        guard case .text(let seen)? = entries.first(where: { $0.key == "content" })?.value else {
            throw GuestBootError.failure("guest mount did not return the probe content")
        }
        guard seen == probeContent else { throw GuestBootError.failure("share probe mismatch") }
    }
    if case .text(let location)? = entries.first(where: { $0.key == "location" })?.value {
        return location
    }
    return nil
}

/// Drop the guest mount, then the share from the device. Best effort: a
/// stopped guest has nothing mounted and an unmount failure is not worth
/// failing the op over.
nonisolated func unmountShare(_ record: VmRecord, _ share: VmShare, remaining: [VmShare]) {
    guard let g = liveVMs.peek(record.uuid) else { return }
    let body = CBOR.map([
        ("op", .text("unmount")),
        ("path", .text(share.guestPath)),
    ])
    _ = try? GuestChannel.shared(g, body: body)
    _ = applyShares(remaining, of: record, to: g)
}

/// Mount every registered share. The agent's mount command unmounts an
/// existing mount point first, so the same path works for a fresh boot and
/// for a resume (re-binding is harmless when the mount survived the pause).
nonisolated func remountShares(_ record: VmRecord) {
    guard let shares = record.shares, !shares.isEmpty else { return }
    for share in shares {
        try? mountShare(record, share, probe: false, allShares: shares)
    }
}

nonisolated func addShare(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("id") else { return r.fail("missing id") }
    guard case .text(let hostPath)? = r.arg("hostPath") else { return r.fail("missing hostPath") }
    let record = try registry.resolve(id)
    // Replacing the share set breaks reads in flight, so not during a drop.
    if let live = liveVMs.peek(record.uuid), activeDrops.get(live.boot) != nil {
        return r.fail("a drop is running on \(record.name); change shares when it finishes")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory),
        isDirectory.boolValue
    else {
        return r.fail("host path is not a directory: \(hostPath)")
    }
    let guestPath: String
    if case .text(let given)? = r.arg("guestPath") {
        guestPath = given
    } else {
        guestPath = "/mnt/openvm/" + URL(fileURLWithPath: hostPath).lastPathComponent
    }
    guard validGuestPath(guestPath) else {
        return r.fail("guest path must be absolute and free of '..'")
    }
    let updated = try registry.addShare(record.uuid, hostPath: hostPath, guestPath: guestPath)
    var note = "registered (mounts at next start)"
    if liveVMs.peek(record.uuid) != nil {
        let location = try mountShare(
            record, VmShare(hostPath: hostPath, guestPath: guestPath),
            probe: true, allShares: updated.shares ?? [])
        note = "mounted at \(location ?? guestPath)"
    }
    return r.ok([("message", .text("share added: \(hostPath) -> \(guestPath) (\(note))"))])
}

nonisolated func removeShare(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("id") else { return r.fail("missing id") }
    guard case .text(let hostPath)? = r.arg("hostPath") else { return r.fail("missing hostPath") }
    let record = try registry.resolve(id)
    // Replacing the share set breaks reads in flight, so not during a drop.
    if let live = liveVMs.peek(record.uuid), activeDrops.get(live.boot) != nil {
        return r.fail("a drop is running on \(record.name); change shares when it finishes")
    }
    if let share = record.shares?.first(where: { $0.hostPath == hostPath }) {
        unmountShare(
            record, share,
            remaining: (record.shares ?? []).filter { $0.hostPath != hostPath })
    }
    _ = try registry.removeShare(record.uuid, hostPath: hostPath)
    return r.ok([("message", .text("share removed: \(hostPath)"))])
}

nonisolated func listShares(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    let rows: [CBOR] = (record.shares ?? []).map {
        .map([("hostPath", .text($0.hostPath)), ("guestPath", .text($0.guestPath))])
    }
    return r.ok([("shares", .array(rows))])
}
