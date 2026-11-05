// DragControl — files dragged into a guest.
//
//   stage  clone the items into a new folder under the VM's read-only `drops`
//          share: instant on APFS, the guest never sees the originals, and a
//          later edit cannot tear the copy
//   copy   the agent copies to the user's Desktop, as that user, in the background
//   poll   `status` until done, then the staging folder goes
//
// The device's share set is never touched. Replacing it mid-copy failed the copy
// on both guests, so `drops` is there from boot and share changes wait for a drop.
//
// The client polls rather than the daemon, because the daemon serves one client
// at a time and a large tree must not stop every other VM's ops.
import Foundation
import OpenVMCore

nonisolated final class ActiveDrops: @unchecked Sendable {
    struct Drop {
        let staging: URL
    }

    private let lock = NSLock()
    private var drops: [UUID: Drop] = [:]

    func set(_ boot: UUID, _ drop: Drop) {
        lock.lock()
        defer { lock.unlock() }
        drops[boot] = drop
    }

    func get(_ boot: UUID) -> Drop? {
        lock.lock()
        defer { lock.unlock() }
        return drops[boot]
    }

    func take(_ boot: UUID) -> Drop? {
        lock.lock()
        defer { lock.unlock() }
        return drops.removeValue(forKey: boot)
    }
}

nonisolated let activeDrops = ActiveDrops()

/// The VM's `drops` share on the host.
nonisolated func dropRoot(_ uuid: String, create: Bool) throws -> URL {
    let root = home.appendingPathComponent("drops").appendingPathComponent(uuid)
    if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    return root
}

/// A previous daemon's staging folders: their drops died with it.
nonisolated func clearDropStaging() {
    try? FileManager.default.removeItem(at: home.appendingPathComponent("drops"))
}

/// The guest user must be able to read what it is given, and a clone keeps the
/// source's modes. The clone is ours to change; symlinks are left as they are.
private nonisolated func makeReadable(_ root: URL) throws {
    let fm = FileManager.default
    var targets = [root]
    if let walk = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let url as URL in walk { targets.append(url) }
    }
    for url in targets {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular else { continue }
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let wanted = type == .typeDirectory ? mode | 0o755 : mode | 0o644
        if wanted != mode { try fm.setAttributes([.posixPermissions: wanted], ofItemAtPath: url.path) }
    }
}

nonisolated func startDrop(_ record: VmRecord, _ g: LiveGuest, paths: [String]) throws -> [(
    key: String, value: CBOR
)] {
    guard activeDrops.get(g.boot) == nil else { throw GuestBootError.failure("a drop is already running") }
    let names: [String]
    switch DragDrop.itemNames(for: paths) {
    case .success(let result): names = result
    case .failure(let error): throw GuestBootError.failure(error.description)
    }
    // Ask first: nothing is copied for a guest with nobody to give it to.
    _ = try GuestChannel.drag(g, body: .map([("op", .text("enter"))]))

    let fm = FileManager.default
    let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let staging = try dropRoot(record.uuid, create: true).appendingPathComponent(id)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    do {
        for (path, name) in zip(paths, names) {
            let target = staging.appendingPathComponent(name)
            try fm.copyItem(at: URL(fileURLWithPath: path), to: target)
            try makeReadable(target)
        }
        activeDrops.set(g.boot, .init(staging: staging))
        let reply = try GuestChannel.drag(
            g,
            body: .map([
                ("op", .text("drop")), ("share", .text(id)),
                ("items", .array(names.map { .text($0) })),
            ]), timeoutSeconds: 20)
        guard case .map(let result) = reply else {
            throw GuestBootError.failure("guest drag reply was not a map")
        }
        return result
    } catch {
        finishDrop(g)
        try? fm.removeItem(at: staging)
        throw error
    }
}

/// The poll. The staging folder goes once the guest says it is done.
nonisolated func dropStatus(_ record: VmRecord, _ g: LiveGuest) throws -> [(key: String, value: CBOR)] {
    let reply = try GuestChannel.drag(g, body: .map([("op", .text("status"))]), acceptError: true)
    guard case .map(let result) = reply, let status = DragDrop.status(reply) else {
        throw GuestBootError.failure("guest drag status was not understood")
    }
    if status.done { finishDrop(g) }
    return result
}

nonisolated func finishDrop(_ g: LiveGuest) {
    guard let drop = activeDrops.take(g.boot) else { return }
    try? FileManager.default.removeItem(at: drop.staging)
}
