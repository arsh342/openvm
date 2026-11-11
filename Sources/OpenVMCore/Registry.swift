// The VM registry: records in vms.json, and the rules for moving between states.
import Foundation

/// Lifecycle states of a VM record. `stopped` and `running` are the base
/// edges; `suspended` is the pause state (a live guest paused by the
/// daemon; it may resume, stop, or nothing else). `starting`/`stopping` exist
/// because the real engine will need them and callers must not treat them as
/// legal start/stop sources.
public nonisolated enum VmState: String, Codable, Sendable {
    case stopped, starting, running, stopping, suspended
}

/// Boot mode of the VM. Determines which boot loader and device model to use.
public nonisolated enum BootMode: String, Codable, Sendable {
    /// openVM's own Alpine guest, which it no longer makes or runs. The value stays, spelt as it was
    /// written, because a record with a value the reader does not know fails the whole registry read.
    case alpine = "linux"
    case windows
    /// Any ARM64 Linux, booted by UEFI from its own ISO, with its own installer.
    case linuxISO = "linux-iso"

    /// Whether the guest runs openVM's agent. Only Windows guests do: a distribution's own install has
    /// none, so nothing that needs the guest channel (clipboard, drops, sending files, the clock)
    /// applies to it, and an Alpine guest never runs.
    public var hasAgent: Bool { self == .windows }

    /// The modes a VM can be made in, or changed to.
    public static let offered: [BootMode] = [.windows, .linuxISO]
}

/// One VM, as stored in vms.json. See docs/vm-records.md.
public nonisolated struct VmRecord: Codable, Sendable, Equatable {
    public var uuid: String
    public var name: String
    public var state: VmState
    public var cpus: Int
    public var memoryMB: Int
    public var diskPath: String?
    public var timezone: String?  // IANA zone (e.g. "Europe/Berlin"); nil = guest default
    public var shares: [VmShare]?  // host folders exported into the guest; nil = none
    public var bootMode: BootMode?  // windows or linux-iso; absent in the oldest records, which were Alpine guests
    public var variableStorePath: String?  // Windows: EFI variable store path
    public var installMediaPath: String?  // Windows: media from tools/build/mk-windows-media.sh, used until installed
    public var machineIdentifier: String?  // Windows: base64 VZGenericMachineIdentifier, stable across boots
    public var clipboardSync: Bool? = nil  // share the clipboard when the VM's window is active; nil = on
    public var outbox: Bool? = nil  // take files the guest sends to the Mac; nil = on
    public var createdAt: String  // ISO8601; the registry stays human-readable

    /// Whether the clipboard is shared with this VM. A record from before the setting existed
    /// has none, and that means on, except for a guest installed from its own ISO: its clipboard goes
    /// through the framework's Spice agent, which shares passwords too, so it waits to be asked.
    public var syncsClipboard: Bool { clipboardSync ?? (bootMode != .linuxISO) }

    /// The mode this VM boots in. A record written before the field existed has none, and those were
    /// all Alpine guests.
    public var mode: BootMode { bootMode ?? .alpine }

    /// An Alpine guest from an earlier openVM. It stays in the list and can be deleted, but not started.
    public var isRetiredAlpine: Bool { mode == .alpine }

    /// What `start` and `set` say about such a VM.
    public var retiredAlpineMessage: String {
        "\(name) is an Alpine guest, which openVM no longer runs. Deleting it removes its disk"
            + (diskPath.map { ", so copy \($0) first if you want to keep it" } ?? "")
    }

    /// Whether files the guest sends are taken to the Mac. Missing means on.
    public var acceptsOutbox: Bool { outbox ?? true }
}

/// A host directory shared into the guest over virtio-fs.
public nonisolated struct VmShare: Codable, Sendable, Equatable {
    public var hostPath: String
    public var guestPath: String

    public init(hostPath: String, guestPath: String) {
        self.hostPath = hostPath
        self.guestPath = guestPath
    }
}

/// Why a registry operation failed.
public nonisolated enum VmRegistryError: Error, Equatable {
    case nameInvalid
    case nameExists
    case notFound
    case badTransition
    case io(String)
}

/// The VM registry: one JSON file, whole-file read/write, no locking.
/// The daemon is single-client, so a lock file is unnecessary;
/// upgrade to a shared lock if multiple daemons ever run at once.
public nonisolated struct VmRegistry: Sendable {
    public let path: URL

    /// Default location: $OPENVM_HOME/vms.json, else ~/.openvm/vms.json.
    public static func defaultPath() -> URL {
        if let home = ProcessInfo.processInfo.environment["OPENVM_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("vms.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openvm/vms.json")
    }

    public init(path: URL = VmRegistry.defaultPath()) {
        self.path = path
    }

    // MARK: queries

    /// Every VM record. A missing file is an empty list.
    public func list() throws -> [VmRecord] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw VmRegistryError.io("read \(path.path): \(error)")
        }
        do {
            return try JSONDecoder().decode(Container.self, from: data).vms
        } catch {
            throw VmRegistryError.io("decode \(path.path): \(error)")
        }
    }

    /// Resolve an identifier that is either a UUID or a name.
    public func resolve(_ id: String) throws -> VmRecord {
        let vms = try list()
        guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
        return vms[idx]
    }

    /// The one identifier rule every lookup uses: a UUID in any letter case,
    /// or an exact name. Every operation shares it, so an id that resolves can
    /// never then fail a state transition with `notFound`.
    static func index(of id: String, in vms: [VmRecord]) -> Int? {
        let lower = id.lowercased()
        return vms.firstIndex(where: { $0.uuid.lowercased() == lower || $0.name == id })
    }

    // MARK: transitions

    /// start: only `stopped` may become `running`.
    public func start(_ id: String) throws -> VmRecord {
        try transition(id, from: [.stopped], to: .running)
    }

    /// stop: `running` or `suspended` may become `stopped`; a suspended guest
    /// orphaned by a daemon restart still needs a way out.
    public func stop(_ id: String) throws -> VmRecord {
        try transition(id, from: [.running, .suspended], to: .stopped)
    }

    /// suspend: only `running` may become `suspended`.
    public func suspend(_ id: String) throws -> VmRecord {
        try transition(id, from: [.running], to: .suspended)
    }

    /// resume: only `suspended` may become `running`.
    public func resume(_ id: String) throws -> VmRecord {
        try transition(id, from: [.suspended], to: .running)
    }

    /// delete: removes the record outright; only a `stopped` VM may be removed
    /// (disk sidecar sweep is the daemon's job — the registry stays disk-agnostic).
    public func delete(_ id: String) throws -> VmRecord {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            guard vms[idx].state == .stopped else { throw VmRegistryError.badTransition }
            return vms.remove(at: idx)
        }
    }

    /// Record a VM's machine identifier (generated once, on its first boot).
    public func setMachineIdentifier(_ id: String, _ value: String) throws {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            vms[idx].machineIdentifier = value
        }
    }

    /// Forgets the install media: it was removed once the install finished, so the record must not
    /// point at a file that is gone. Already forgotten is fine.
    public func clearInstallMedia(_ id: String) throws {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            vms[idx].installMediaPath = nil
        }
    }

    /// Updates the given fields of a stopped VM; nil leaves a field unchanged.
    /// The daemon op owns the "at least one field" presence check.
    public func set(
        _ id: String, cpus: Int? = nil, memoryMB: Int? = nil,
        timezone: String? = nil, bootMode: BootMode? = nil,
        variableStorePath: String? = nil, clipboardSync: Bool? = nil, outbox: Bool? = nil
    ) throws -> VmRecord {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            // CPUs, memory and the boot setup are read when the VM boots. The time zone and the
            // clipboard policy are not, so they may change while it runs.
            let needsStopped = cpus != nil || memoryMB != nil || bootMode != nil || variableStorePath != nil
            if needsStopped, vms[idx].state != .stopped { throw VmRegistryError.badTransition }
            if let cpus { vms[idx].cpus = cpus }
            if let memoryMB { vms[idx].memoryMB = memoryMB }
            if let timezone { vms[idx].timezone = timezone }
            if let bootMode { vms[idx].bootMode = bootMode }
            if let variableStorePath { vms[idx].variableStorePath = variableStorePath }
            if let clipboardSync { vms[idx].clipboardSync = clipboardSync }
            if let outbox { vms[idx].outbox = outbox }
            return vms[idx]
        }
    }

    /// Adds a stopped VM. The name must be valid and unused.
    public func create(
        name: String, cpus: Int = 4, memoryMB: Int = 4096,
        diskPath: String? = nil, bootMode: BootMode,
        variableStorePath: String? = nil, installMediaPath: String? = nil
    ) throws -> VmRecord {
        guard Self.validName(name) else { throw VmRegistryError.nameInvalid }
        return try mutate { vms in
            guard !vms.contains(where: { $0.name == name }) else { throw VmRegistryError.nameExists }
            let vm = VmRecord(
                uuid: UUID().uuidString,
                name: name,
                state: .stopped,
                cpus: cpus, memoryMB: memoryMB, diskPath: diskPath, timezone: nil, shares: nil,
                bootMode: bootMode, variableStorePath: variableStorePath,
                installMediaPath: installMediaPath, machineIdentifier: nil,
                createdAt: Self.iso8601.string(from: Date()))
            vms.append(vm)
            return vm
        }
    }

    // MARK: shares

    /// addShare: export a host directory into the guest. One entry per host
    /// path — re-adding the same host path moves its guest path.
    public func addShare(_ id: String, hostPath: String, guestPath: String) throws -> VmRecord {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            var shares = vms[idx].shares ?? []
            if let existing = shares.firstIndex(where: { $0.hostPath == hostPath }) {
                shares[existing].guestPath = guestPath
            } else {
                shares.append(VmShare(hostPath: hostPath, guestPath: guestPath))
            }
            vms[idx].shares = shares
            return vms[idx]
        }
    }

    /// removeShare: drop the export for one host path (unknown paths are a no-op).
    public func removeShare(_ id: String, hostPath: String) throws -> VmRecord {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            vms[idx].shares = (vms[idx].shares ?? []).filter { $0.hostPath != hostPath }
            return vms[idx]
        }
    }

    // MARK: internals

    /// Every write goes through here: connections are served on their own threads, so
    /// two read-modify-write cycles must never interleave and lose a record. One lock
    /// for the process is enough: the host lock keeps a second host off the same home.
    private static let writeLock = NSLock()

    /// Reads the records, lets `change` edit them, and saves the result — as one step.
    /// Nothing is saved when `change` throws.
    private func mutate<T>(_ change: (inout [VmRecord]) throws -> T) throws -> T {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        var vms = try list()
        let result = try change(&vms)
        try save(vms)
        return result
    }

    private func transition(_ id: String, from allowed: Set<VmState>, to: VmState) throws -> VmRecord {
        try mutate { vms in
            guard let idx = Self.index(of: id, in: vms) else { throw VmRegistryError.notFound }
            guard allowed.contains(vms[idx].state) else { throw VmRegistryError.badTransition }
            vms[idx].state = to
            return vms[idx]
        }
    }

    private func save(_ vms: [VmRecord]) throws {
        do {
            let dir = path.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Container(vms: vms))
            try data.write(to: path, options: [.atomic])
        } catch {
            throw VmRegistryError.io("write \(path.path): \(error)")
        }
    }

    /// 1–64 chars of [A-Za-z0-9_-] whose first char is alphanumeric (rejects "-x"/"_x":
    /// they look like CLI flags and are not a legal hostname segment); safe as a CLI
    /// argument, a directory name and a hostname segment.
    public static func validName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), name.unicodeScalars.count == name.count else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var it = name.unicodeScalars.makeIterator()
        guard let first = it.next(), allowed.contains(first),
            !CharacterSet(charactersIn: "-_").contains(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // ISO8601DateFormatter is documented thread-safe; opt out of actor isolation checks.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private struct Container: Codable {
        var vms: [VmRecord]
    }
}
