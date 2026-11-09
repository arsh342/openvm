// ActivityTable — what each VM is doing right now, so two clients cannot start
// the same boot, and a window can show "Starting…" while a boot is in flight.
//
// Memory only, on purpose: the registry's state says what a VM *is*, this says
// what is being done to it. A host that dies mid-boot leaves a clean `stopped`
// record and an empty table.
import Foundation

nonisolated final class ActivityTable: @unchecked Sendable {
    private let lock = NSLock()
    private var ops: [String: String] = [:]

    /// Claims the VM for `op`. False when something else already holds it.
    func begin(_ uuid: String, _ op: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ops[uuid] == nil else { return false }
        ops[uuid] = op
        return true
    }

    func end(_ uuid: String) {
        lock.lock()
        defer { lock.unlock() }
        ops[uuid] = nil
    }

    func current(_ uuid: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return ops[uuid]
    }
}

nonisolated let activity = ActivityTable()

/// The ops that change a VM's life. They hold its slot while they run.
nonisolated let slotOps: Set<String> = ["start", "stop", "suspend", "resume", "delete", "set"]

/// The VMs whose Windows install is running. A person closing the app should be told
/// before that is thrown away, so the list reports it.
nonisolated final class InstallTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var running = Set<String>()

    func begin(_ uuid: String) {
        lock.lock()
        defer { lock.unlock() }
        running.insert(uuid)
    }

    func end(_ uuid: String) {
        lock.lock()
        defer { lock.unlock() }
        running.remove(uuid)
    }

    func contains(_ uuid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running.contains(uuid)
    }
}

nonisolated let installs = InstallTracker()
