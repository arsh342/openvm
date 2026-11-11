// VmRecordOps — operations on a VM's record: create, list, info, delete, set.
import Foundation
import OpenVMCore

/// One registry record as a vmReply row; shared by `list` and `info`.
nonisolated func vmRow(_ rec: VmRecord) -> [(key: String, value: CBOR)] {
    var row: [(key: String, value: CBOR)] = [
        ("name", .text(rec.name)),
        ("state", .text(rec.state.rawValue)),
        ("uuid", .text(rec.uuid)),
        ("cpus", .uint(UInt64(rec.cpus))),
        ("memoryMB", .uint(UInt64(rec.memoryMB))),
    ]
    if let disk = rec.diskPath {
        row.append(("diskPath", .text(disk)))
        // The disk is sparse, so this is its size as the guest sees it, not what it uses.
        if let size = (try? FileManager.default.attributesOfItem(atPath: disk))?[.size] as? NSNumber {
            row.append(("diskBytes", .uint(size.uint64Value)))
        }
    }
    row.append(("bootMode", .text(rec.mode.rawValue)))
    if let tz = rec.timezone { row.append(("timezone", .text(tz))) }
    if let busy = activity.current(rec.uuid) { row.append(("activity", .text(busy))) }
    if installs.contains(rec.uuid) { row.append(("installing", .bool(true))) }
    if let live = liveVMs.peek(rec.uuid), activeDrops.get(live.boot) != nil {
        row.append(("dropping", .bool(true)))
    }
    row.append(("clipboardSync", .bool(rec.syncsClipboard)))
    row.append(("outbox", .bool(rec.acceptsOutbox)))
    if rec.bootMode == .linuxISO, rec.installMediaPath != nil { row.append(("installerAttached", .bool(true))) }
    return row
}

/// IANA zone name check: components of [A-Za-z0-9_+-] separated by "/", each
/// starting with a letter. The guest turns this into a /usr/share/zoneinfo
/// path, so traversal characters are rejected here and again in the agent.
nonisolated func validTimezone(_ tz: String) -> Bool {
    guard !tz.isEmpty, tz.utf8.count <= 64 else { return false }
    let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")
    for part in tz.split(separator: "/", omittingEmptySubsequences: false) {
        guard !part.isEmpty, part.unicodeScalars.allSatisfy({ allowed.contains($0) }),
            let first = part.unicodeScalars.first, CharacterSet.letters.contains(first)
        else { return false }
    }
    return true
}

/// Two creates of one name would both pass the name check, and the loser's cleanup would
/// delete the winner's disk directory. One at a time closes that.
private nonisolated let createLock = NSLock()

nonisolated func createVm(_ r: VmRequest) throws -> Envelope {
    createLock.lock()
    defer { createLock.unlock() }
    guard case .text(let name)? = r.arg("name") else { return r.fail("missing name") }
    var cpus = 4
    if case .uint(let n)? = r.arg("cpus"), n >= 1, n <= 32 {
        cpus = Int(n)
    }
    var memoryMB = 4096
    if case .uint(let n)? = r.arg("memoryMB"), n >= 128 {
        memoryMB = Int(n)
    }
    var diskSizeMB = 32 * 1024
    if case .uint(let n)? = r.arg("diskSizeMB") {
        guard n >= 1024, n <= 1_048_576 else { return r.fail("diskSizeMB must be between 1024 and 1048576") }
        diskSizeMB = Int(n)
    }
    guard case .text(let modeText)? = r.arg("boot-mode") else {
        return r.fail("create needs --boot-mode windows or linux-iso")
    }
    guard let bootMode = BootMode(rawValue: modeText), BootMode.offered.contains(bootMode) else {
        return r.fail(
            modeText == BootMode.alpine.rawValue
                ? "openVM no longer makes Alpine guests: install Linux from its own ISO with --boot-mode linux-iso"
                : "boot-mode must be windows or linux-iso")
    }
    var variableStorePath: String?
    if case .text(let path)? = r.arg("variable-store-path") {
        variableStorePath = path
    }
    var installMediaPath: String?
    if case .text(let path)? = r.arg("install-media") {
        guard FileManager.default.fileExists(atPath: path) else {
            return r.fail("install media not found: \(path)")
        }
        installMediaPath = URL(fileURLWithPath: path).standardizedFileURL.path
    }
    if bootMode == .linuxISO, installMediaPath == nil { return r.fail("--boot-mode linux-iso needs --install-media <iso>") }
    guard !((try registry.list()).contains { $0.name == name }) else {
        return r.fail("nameExists")
    }
    guard VmRegistry.validName(name) else { return r.fail("nameInvalid") }
    let diskDirectory = home.appendingPathComponent("disks", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: diskDirectory.path) else {
        return r.fail("disk directory already exists: \(diskDirectory.path)")
    }
    try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    let diskURL = diskDirectory.appendingPathComponent("disk.raw")
    guard FileManager.default.createFile(atPath: diskURL.path, contents: Data()) else {
        try? FileManager.default.removeItem(at: diskDirectory)
        return r.fail("could not create disk image at \(diskURL.path)")
    }
    do {
        let disk = try FileHandle(forWritingTo: diskURL)
        try disk.truncate(atOffset: UInt64(diskSizeMB) * 1_048_576)
        try disk.close()
    } catch {
        try? FileManager.default.removeItem(at: diskDirectory)
        throw VmRegistryError.io("create disk image: \(error)")
    }
    let record: VmRecord
    do {
        record = try registry.create(
            name: name, cpus: cpus, memoryMB: memoryMB,
            diskPath: diskURL.path, bootMode: bootMode,
            variableStorePath: variableStorePath,
            installMediaPath: installMediaPath)
    } catch {
        try? FileManager.default.removeItem(at: diskDirectory)
        throw error
    }
    return r.ok([
        ("message", .text("created \(record.name) with \(diskSizeMB) MiB disk")),
        ("uuid", .text(record.uuid)),
    ])
}

nonisolated func listVms(_ r: VmRequest) throws -> Envelope {
    let vms = try registry.list().map { CBOR.map(vmRow($0)) }
    return r.ok([("vms", .array(vms))])
}

nonisolated func vmInfo(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    return r.ok([("vms", .array([.map(vmRow(record))]))])
}

nonisolated func deleteVm(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    guard liveVMs.peek(record.uuid) == nil else {
        return r.fail("delete requires a stopped VM (\(record.name) is live in this daemon)")
    }
    if let diskPath = record.diskPath {
        let diskURL = URL(fileURLWithPath: diskPath)
        let directory = diskURL.deletingLastPathComponent()
        // The install media openVM built for this VM goes with it (never a file it did not make).
        if let media = record.installMediaPath { _ = removeOwnedMedia(media, mediaRoot: mediaFolder) }
        // sidecars live next to the disk (installed marker + exported kernel/initramfs)
        for extensionName in ["openvm-installed", "openvm-kernel", "openvm-initramfs"] {
            try? FileManager.default.removeItem(at: diskURL.appendingPathExtension(extensionName))
        }
        // A Windows VM's EFI variable store defaults to nvram.bin beside the
        // disk (GuestBoot.bootWindows). Left behind, it made the rmdir below
        // fail and `create` refuse the name forever after. A store the user
        // placed elsewhere with --variable-store-path is theirs; leave it.
        let defaultStore = directory.appendingPathComponent("nvram.bin")
        if record.variableStorePath == nil || record.variableStorePath == defaultStore.path {
            try? FileManager.default.removeItem(at: defaultStore)
        }
        do {
            try FileManager.default.removeItem(at: diskURL)
        } catch {
            return r.fail("could not remove disk image: \(error)")
        }
        // rmdir only: never recursively delete a shared directory. A failed rmdir
        // leaves an empty disks/<name>/ behind.
        rmdir(directory.path)
    }
    _ = try registry.delete(record.uuid)
    return r.ok([("message", .text("deleted \(record.name)"))])
}

nonisolated func setVm(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("id") else { return r.fail("missing id") }
    var cpus: Int?
    if case .uint(let n)? = r.arg("cpus") {
        guard n >= 1, n <= UInt64(ResourceLimits.cpuCeiling) else {
            return r.fail("cpus must be between 1 and \(ResourceLimits.cpuCeiling)")
        }
        cpus = Int(n)
    }
    var memoryMB: Int?
    if case .uint(let n)? = r.arg("memoryMB") {
        guard n >= 128 else { return r.fail("memoryMB must be at least 128") }
        memoryMB = Int(n)
    }
    var timezone: String?
    if case .text(let tz)? = r.arg("tz") {
        guard validTimezone(tz) else {
            return r.fail("tz must be an IANA zone name like Europe/Berlin")
        }
        timezone = tz
    }
    var bootMode: BootMode?
    if case .text(let mode)? = r.arg("boot-mode") {
        guard let m = BootMode(rawValue: mode), BootMode.offered.contains(m) else {
            return r.fail("boot-mode must be windows or linux-iso")
        }
        bootMode = m
    }
    var variableStorePath: String?
    if case .text(let path)? = r.arg("variable-store-path") {
        variableStorePath = path
    }
    var clipboardSync: Bool?
    if case .bool(let on)? = r.arg("clipboard-sync") { clipboardSync = on }
    var outbox: Bool?
    if case .bool(let on)? = r.arg("outbox") { outbox = on }
    guard cpus != nil || memoryMB != nil || timezone != nil || bootMode != nil || variableStorePath != nil
        || clipboardSync != nil || outbox != nil
    else {
        return r.fail(
            "set requires at least one of cpus, memoryMB, tz, boot-mode, variable-store-path, clipboard-sync, outbox")
    }
    if let problem = validateResources(cpus: cpus, memoryMB: memoryMB, limits: .current) { return r.fail(problem) }
    let record = try registry.resolve(id)
    // An Alpine disk does not become another system by renaming its mode.
    if bootMode != nil, record.isRetiredAlpine { return r.fail(record.retiredAlpineMessage) }
    // CPUs, memory and the boot setup are read at boot; the time zone and the clipboard policy
    // are not, so they can change while the VM runs.
    if cpus != nil || memoryMB != nil || bootMode != nil || variableStorePath != nil {
        guard record.state == .stopped else {
            return r.fail("changing CPUs or memory needs a stopped VM (state=\(record.state.rawValue))")
        }
        guard liveVMs.peek(record.uuid) == nil else {
            // defensive: a stopped record with a live handle should not exist
            return r.fail("changing CPUs or memory needs a stopped VM (\(record.name) is live in this daemon)")
        }
    }
    _ = try registry.set(
        record.uuid, cpus: cpus, memoryMB: memoryMB, timezone: timezone, bootMode: bootMode,
        variableStorePath: variableStorePath, clipboardSync: clipboardSync, outbox: outbox)
    var applied: [String] = []
    if let cpus { applied.append("cpus=\(cpus)") }
    if let memoryMB { applied.append("memoryMB=\(memoryMB)") }
    if let timezone { applied.append("tz=\(timezone)") }
    if let bootMode { applied.append("boot-mode=\(bootMode.rawValue)") }
    if let variableStorePath { applied.append("variable-store-path=\(variableStorePath)") }
    if let clipboardSync { applied.append("clipboard-sync=\(clipboardSync)") }
    if let outbox {
        applied.append("outbox=\(outbox)")
        // A running guest's watcher follows the switch at once.
        if liveVMs.peek(record.uuid) != nil {
            if outbox { outboxWatchers.start(uuid: record.uuid, name: record.name) } else { outboxWatchers.stop(uuid: record.uuid) }
        }
    }
    return r.ok([("message", .text("set \(record.name) (\(applied.joined(separator: ", ")))"))])
}
