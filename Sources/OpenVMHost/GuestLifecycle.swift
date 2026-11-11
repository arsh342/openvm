// GuestLifecycle — keeping a VM's recorded state true to what its guest does.
//
// The registry says what a VM is. Until now only a client's `stop` could change it
// back to `stopped`, so a guest that shut itself down (Start menu, `poweroff`)
// stayed `running` for ever. The framework tells us when a guest stops, and
// everything that ends a guest funnels into `reapGuest`, which is safe to call
// twice: the delegate and a host-requested stop can both report the same end.
import Foundation
import OpenVMCore
import Virtualization

/// Where a guest is in its boot. Channel operations need a guest that is ready;
/// a window can show one that is still booting.
nonisolated enum GuestPhase: Sendable, Equatable {
    case booting, ready
}

nonisolated func channelRefusal(phase: GuestPhase, name: String) -> String? {
    phase == .booting ? "\(name) is still booting; wait for it to start" : nil
}

nonisolated enum StopReason {
    case hostRequested, guestStopped
    case error(String)
}

/// Moves a record to `stopped`. A record that is already stopped, or gone, is fine:
/// a second report of the same end must not turn into an error.
nonisolated func markStopped(_ registry: VmRegistry, _ uuid: String) {
    do {
        _ = try registry.stop(uuid)
    } catch VmRegistryError.badTransition, VmRegistryError.notFound {
        return
    } catch {
        note("openvmd: could not record \(uuid) as stopped: \(error)")
    }
}

/// A stop report counts only for the boot it came from. A VM that was stopped and
/// started again must not be ended by the first boot's late report.
nonisolated func shouldReap(held: UUID?, reported: UUID) -> Bool {
    held == reported
}

/// Records that say a guest is live although this host holds none. After a host
/// restart that is every `running` or `suspended` record: the guest died with the
/// process that ran it.
nonisolated func reconcileRecords(_ records: [VmRecord], live: Set<String>) -> [String] {
    records.filter { ($0.state == .running || $0.state == .suspended) && !live.contains($0.uuid) }
        .map(\.uuid)
}

/// What a life-changing op does about its VM's slot.
nonisolated enum SlotDecision: Equatable {
    case take, passThrough
    case busy(String)
}

/// A VM runs one life-changing op at a time. A `stop` is let through a `start`:
/// it is how a boot is cancelled.
nonisolated func slotDecision(op: String, holder: String?) -> SlotDecision {
    guard let holder else { return .take }
    if op == "stop", holder == "start" { return .passThrough }
    return .busy(holder)
}

/// Ends this host's hold on a guest that has stopped. Idempotent.
nonisolated func reapGuest(uuid: String, boot: UUID, reason: StopReason) {
    guard liveVMs.takeIfBoot(uuid, boot) != nil else { return }
    if let drop = activeDrops.take(boot) { try? FileManager.default.removeItem(at: drop.staging) }
    displayModes.clear(uuid)
    outboxWatchers.stop(uuid: uuid)
    markStopped(registry, uuid)
    switch reason {
    case .hostRequested: break
    case .guestStopped:
        note("openvmd: \(uuid): the guest stopped")
    case .error(let message): note("openvmd: \(uuid): the guest stopped with an error: \(message)")
    }
}

/// Told by the framework when a guest ends. The framework holds its delegate weakly,
/// so the `LiveGuest` keeps this alive.
nonisolated final class GuestDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    let uuid: String
    let boot: UUID

    init(uuid: String, boot: UUID) {
        self.uuid = uuid
        self.boot = boot
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        reapGuest(uuid: uuid, boot: boot, reason: .guestStopped)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        reapGuest(uuid: uuid, boot: boot, reason: .error("\(error)"))
    }
}

/// How many of the guests that were live are gone now.
nonisolated func stoppedCount(before: Set<String>, after: Set<String>) -> Int {
    before.subtracting(after).count
}
