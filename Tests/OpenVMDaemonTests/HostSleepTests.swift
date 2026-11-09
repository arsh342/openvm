// Tests for the host sleep policy.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

/// The host-sleep handshake cannot be exercised in CI (it needs the machine to
/// sleep), so the policy it follows is pinned down here: only the running
/// guests with a live channel take part.
@Suite struct HostSleepTests {
    private func makeRegistry() throws -> (VmRegistry, URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("openvm-hostsleep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (VmRegistry(path: home.appendingPathComponent("vms.json")), home)
    }

    @Test("the host sleep takes the running guests with a live channel")
    func selectsRunningLiveGuests() throws {
        let (registry, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let running = try registry.create(name: "running")
        let stopped = try registry.create(name: "stopped")
        _ = try registry.start(running.uuid)

        let picked = guestsForHostSleep(try registry.list(), liveUUIDs: [running.uuid, stopped.uuid])
        #expect(picked.map(\.uuid) == [running.uuid])
    }

    @Test("a guest the user suspended is left alone")
    func skipsUserSuspendedGuests() throws {
        let (registry, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try registry.create(name: "vm")
        _ = try registry.start(vm.uuid)
        _ = try registry.suspend(vm.uuid)

        #expect(guestsForHostSleep(try registry.list(), liveUUIDs: [vm.uuid]).isEmpty)
    }

    @Test("a running guest without a live channel is left alone")
    func skipsRunningGuestsWithoutALiveChannel() throws {
        let (registry, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try registry.create(name: "vm")
        _ = try registry.start(vm.uuid)

        #expect(guestsForHostSleep(try registry.list(), liveUUIDs: []).isEmpty)
    }

    /// Environmental: the machine has to grant the power registration, or the
    /// daemon runs without sleep awareness.
    @Test("the host power watcher registers")
    func theWatcherRegisters() {
        #expect(HostPower.start { _ in })
    }
}
