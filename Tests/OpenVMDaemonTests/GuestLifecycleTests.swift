// A VM's recorded state must follow what the guest does, not only what a client asked for.
import Foundation
import Testing

@testable import OpenVMCore
@testable import OpenVMHost

@Suite struct GuestLifecycleTests {
    private func makeRegistry() throws -> (VmRegistry, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openvm-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (VmRegistry(path: home.appendingPathComponent("vms.json")), home)
    }

    @Test("a guest that stops itself is recorded as stopped, once, and a second report is harmless")
    func guestInitiatedStopReapsOnce() throws {
        let (registry, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try registry.create(name: "w")
        _ = try registry.start(vm.uuid)

        markStopped(registry, vm.uuid)
        markStopped(registry, vm.uuid)  // the delegate and a host stop can both report it

        #expect(try registry.resolve(vm.uuid).state == .stopped)
        markStopped(registry, "no-such-vm")  // and an unknown VM is not an error either
    }

    @Test("a stop report from an old boot cannot end a newer boot of the same VM")
    func staleBootCannotReapANewBoot() {
        let old = UUID(), current = UUID()
        #expect(shouldReap(held: current, reported: current))
        #expect(!shouldReap(held: current, reported: old))
        #expect(!shouldReap(held: nil, reported: old))
    }

    @Test("after a host restart, records that claim a live guest are stopped")
    func orphanedRecordsAreReconciled() throws {
        let (registry, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let running = try registry.create(name: "running")
        let suspended = try registry.create(name: "suspended")
        let stopped = try registry.create(name: "stopped")
        let held = try registry.create(name: "held")
        _ = try registry.start(running.uuid)
        _ = try registry.start(suspended.uuid)
        _ = try registry.suspend(suspended.uuid)
        _ = try registry.start(held.uuid)

        let orphans = reconcileRecords(try registry.list(), live: [held.uuid])
        #expect(Set(orphans) == [running.uuid, suspended.uuid])
        #expect(!orphans.contains(stopped.uuid))
    }

    @Test("a guest that is still booting answers no channel operation")
    func bootingGuestRefusesChannelOps() {
        #expect(channelRefusal(phase: .booting, name: "win")?.contains("booting") == true)
        #expect(channelRefusal(phase: .ready, name: "win") == nil)
    }

    @Test("a stop is let through a start, because it is how a boot is cancelled")
    func stopDuringStartIsAllowed() {
        #expect(slotDecision(op: "stop", holder: "start") == .passThrough)
        #expect(slotDecision(op: "start", holder: nil) == .take)
        #expect(slotDecision(op: "start", holder: "start") == .busy("start"))
        #expect(slotDecision(op: "stop", holder: "stop") == .busy("stop"))
        #expect(slotDecision(op: "delete", holder: "start") == .busy("start"))
    }
}

extension GuestLifecycleTests {
    /// A cancelled boot leaves the table a moment after the stop returns, so the count is
    /// taken against the final state, not against each pass.
    @Test func stopAllCountsWhatWasLiveAndIsGone() {
        #expect(stoppedCount(before: ["a", "b"], after: []) == 2)
        #expect(stoppedCount(before: ["a", "b"], after: ["b"]) == 1)
        #expect(stoppedCount(before: [], after: []) == 0)
        #expect(stoppedCount(before: ["a"], after: ["a"]) == 0)  // one that would not stop is not counted
    }
}
