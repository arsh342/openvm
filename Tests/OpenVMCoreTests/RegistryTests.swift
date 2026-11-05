// Tests for the VM registry.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct RegistryTests {

    // each test gets its own OPENVM_HOME-shaped directory
    fileprivate func makeRegistry(_ fileName: String = "vms.json") throws -> (VmRegistry, URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openvm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (VmRegistry(path: home.appendingPathComponent(fileName)), home)
    }

    @Test func listOnMissingFileIsEmpty() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try reg.list().isEmpty)
    }

    @Test func createPersistsAndLists() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "box-a", cpus: 2, memoryMB: 2048)
        #expect(vm.name == "box-a")
        #expect(vm.state == .stopped)
        #expect(vm.cpus == 2)
        #expect(vm.memoryMB == 2048)
        #expect(UUID(uuidString: vm.uuid) != nil)  // valid uuid
        let again = try VmRegistry(path: home.appendingPathComponent("vms.json")).list()
        #expect(again.count == 1)
        #expect(again[0].uuid == vm.uuid)  // survives a reopen
    }

    @Test func setTimezonePersists() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "tzbox")
        let updated = try reg.set("tzbox", timezone: "Europe/Berlin")
        #expect(updated.timezone == "Europe/Berlin")
        let again = try VmRegistry(path: home.appendingPathComponent("vms.json")).list()
        #expect(again[0].timezone == "Europe/Berlin")
    }

    @Test func setTimezoneLeavesOtherFieldsAlone() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "tzbox2", cpus: 2, memoryMB: 2048)
        let updated = try reg.set("tzbox2", timezone: "UTC")
        #expect(updated.cpus == 2)
        #expect(updated.memoryMB == 2048)
        #expect(updated.timezone == "UTC")
    }

    @Test func recordsWithoutTimezoneStillDecode() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        // a vms.json written before the timezone field existed
        let json = """
            {"vms":[{"uuid":"11111111-2222-3333-4444-555555555555","name":"old","state":"stopped","cpus":4,"memoryMB":4096,"createdAt":"2026-01-01T00:00:00Z"}]}
            """
        try Data(json.utf8).write(to: home.appendingPathComponent("vms.json"))
        let vms = try reg.list()
        #expect(vms.count == 1)
        #expect(vms[0].timezone == nil)
    }

    @Test func defaults() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "dflt")
        #expect(vm.cpus == 4)
        #expect(vm.memoryMB == 4096)
        #expect(vm.diskPath == nil)
    }

    @Test func invalidNamesRejected() async throws {
        let (reg, _) = try makeRegistry()
        for bad in ["", "-lead", "_us", "has space", String(repeating: "a", count: 65)] {
            await #expect(throws: VmRegistryError.nameInvalid) {
                try reg.create(name: bad)
            }
        }
    }

    @Test func nameCollisionRejected() async throws {
        let (reg, home) = try makeRegistry("collide.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "dup")
        await #expect(throws: VmRegistryError.nameExists) {
            try reg.create(name: "dup")
        }
    }

    @Test func resolveByNameAndUUID() throws {
        let (reg, home) = try makeRegistry("resolve.json")
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "findme")
        #expect(try reg.resolve("findme").uuid == vm.uuid)
        #expect(try reg.resolve(vm.uuid).name == vm.name)
    }

    @Test func resolveMissingThrowsNotFound() async throws {
        let (reg, _) = try makeRegistry("missing.json")
        await #expect(throws: VmRegistryError.notFound) {
            try reg.resolve("nope")
        }
    }

    @Test func startStopTransitions() throws {
        let (reg, home) = try makeRegistry("life.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "life")
        #expect(try reg.start("life").state == .running)
        #expect(try reg.stop("life").state == .stopped)
        #expect(try reg.resolve("life").state == .stopped)
    }

    @Test func badTransitionsRejected() async throws {
        let (reg, home) = try makeRegistry("transition.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "one-way")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.stop("one-way")
        }
        _ = try reg.start("one-way")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.start("one-way")
        }
    }

    @Test func deleteRemovesRecordAndPersists() async throws {
        let (reg, home) = try makeRegistry("delete.json")
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "doomed")
        #expect(try reg.delete("doomed").uuid == vm.uuid)
        #expect(try reg.list().isEmpty)
        await #expect(throws: VmRegistryError.notFound) {
            try reg.resolve("doomed")
        }
    }

    @Test func deleteRejectedWhileNotStopped() async throws {
        let (reg, home) = try makeRegistry("deletelive.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "busy")
        _ = try reg.start("busy")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.delete("busy")
        }
    }

    @Test func suspendTransitions() async throws {
        let (reg, home) = try makeRegistry("suspend.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "nap")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.suspend("nap")  // only running may suspend
        }
        _ = try reg.start("nap")
        #expect(try reg.suspend("nap").state == .suspended)
        let reopened = try VmRegistry(path: home.appendingPathComponent("suspend.json"))
        #expect(try reopened.resolve("nap").state == .suspended)
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.suspend("nap")  // suspended may not suspend again
        }
    }

    @Test func resumeTransitions() async throws {
        let (reg, home) = try makeRegistry("resume.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "wake")
        _ = try reg.start("wake")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.resume("wake")  // running may not resume
        }
        _ = try reg.suspend("wake")
        #expect(try reg.resume("wake").state == .running)
    }

    @Test func stopAcceptsSuspendedRecord() async throws {
        let (reg, home) = try makeRegistry("stopsusp.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "out")
        _ = try reg.start("out")
        _ = try reg.suspend("out")
        #expect(try reg.stop("out").state == .stopped)
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.resume("out")  // stopped may not resume
        }
    }

    @Test func setAppliesAndPersists() async throws {
        let (reg, home) = try makeRegistry("set.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "cfg", cpus: 4, memoryMB: 4096)
        let updated = try reg.set("cfg", cpus: 8, memoryMB: 8192)
        #expect(updated.cpus == 8)
        #expect(updated.memoryMB == 8192)
        let reopened = try VmRegistry(path: home.appendingPathComponent("set.json"))
        let rec = try reopened.resolve("cfg")
        #expect(rec.cpus == 8)
        #expect(rec.memoryMB == 8192)
    }

    @Test func setLeavesUntouchedFieldsAlone() async throws {
        let (reg, home) = try makeRegistry("set-partial.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "part", cpus: 2, memoryMB: 2048)
        let updated = try reg.set("part", memoryMB: 4096)
        #expect(updated.cpus == 2)
        #expect(updated.memoryMB == 4096)
    }

    @Test func setRejectedWhileNotStopped() async throws {
        let (reg, home) = try makeRegistry("setrun.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "live")
        _ = try reg.start("live")
        await #expect(throws: VmRegistryError.badTransition) {
            try reg.set("live", cpus: 2)
        }
    }

    @Test func addSharePersists() throws {
        let (reg, home) = try makeRegistry("shares.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "sharer")
        let updated = try reg.addShare("sharer", hostPath: "/host/docs", guestPath: "/mnt/docs")
        #expect(updated.shares?.count == 1)
        #expect(updated.shares?[0].hostPath == "/host/docs")
        #expect(updated.shares?[0].guestPath == "/mnt/docs")
        let reopened = try VmRegistry(path: home.appendingPathComponent("shares.json"))
        #expect(try reopened.resolve("sharer").shares?.count == 1)
    }

    @Test func addShareReplacesTheGuestPathForTheSameHostPath() throws {
        let (reg, home) = try makeRegistry("sharerep.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "sharer2")
        _ = try reg.addShare("sharer2", hostPath: "/host/docs", guestPath: "/mnt/docs")
        let updated = try reg.addShare("sharer2", hostPath: "/host/docs", guestPath: "/mnt/other")
        #expect(updated.shares?.count == 1)
        #expect(updated.shares?[0].guestPath == "/mnt/other")
    }

    @Test func removeShareDropsOnlyThatShare() throws {
        let (reg, home) = try makeRegistry("sharerem.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "sharer3")
        _ = try reg.addShare("sharer3", hostPath: "/host/a", guestPath: "/mnt/a")
        _ = try reg.addShare("sharer3", hostPath: "/host/b", guestPath: "/mnt/b")
        let updated = try reg.removeShare("sharer3", hostPath: "/host/a")
        #expect(updated.shares?.count == 1)
        #expect(updated.shares?[0].hostPath == "/host/b")
    }

    @Test func sharesWorkWhileTheVMRuns() throws {
        let (reg, home) = try makeRegistry("sharerun.json")
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "sharer4")
        _ = try reg.start("sharer4")
        // a share can be added while the guest runs: the daemon mounts it live
        #expect(
            try reg.addShare("sharer4", hostPath: "/host/live", guestPath: "/mnt/live").shares?.count == 1)
    }

    @Test func shareOnUnknownVMThrowsNotFound() async throws {
        let (reg, _) = try makeRegistry("sharenf.json")
        await #expect(throws: VmRegistryError.notFound) {
            try reg.addShare("ghost", hostPath: "/host/x", guestPath: "/mnt/x")
        }
    }

    @Test func recordsWithoutSharesStillDecode() throws {
        let (reg, home) = try makeRegistry("noshares.json")
        defer { try? FileManager.default.removeItem(at: home) }
        // a vms.json written before the shares field existed
        let json = """
            {"vms":[{"uuid":"11111111-2222-3333-4444-555555555555","name":"old","state":"stopped","cpus":4,"memoryMB":4096,"createdAt":"2026-01-01T00:00:00Z"}]}
            """
        try Data(json.utf8).write(to: home.appendingPathComponent("noshares.json"))
        let vms = try reg.list()
        #expect(vms.count == 1)
        #expect(vms[0].shares == nil)
    }

    /// Resolve() ignored UUID case but the mutations did not, so a
    /// lowercase UUID booted a guest and then failed the transition.
    @Test func everyOperationAcceptsAUUIDInAnyCase() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "case-box")
        let lower = vm.uuid.lowercased()
        #expect(try reg.resolve(lower).uuid == vm.uuid)
        #expect(try reg.start(lower).state == .running)
        #expect(try reg.suspend(lower).state == .suspended)
        #expect(try reg.resume(lower).state == .running)
        #expect(try reg.stop(lower).state == .stopped)
        #expect(try reg.set(lower, cpus: 3).cpus == 3)
        #expect(try reg.addShare(lower, hostPath: "/tmp", guestPath: "/mnt/t").shares?.count == 1)
        #expect(try reg.removeShare(lower, hostPath: "/tmp").shares?.isEmpty == true)
        #expect(try reg.delete(lower).uuid == vm.uuid)
    }
}

extension RegistryTests {
    /// Connections are served on their own threads, so creates arrive together.
    @Test func concurrentCreatesKeepEveryRecord() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let group = DispatchGroup()
        for i in 0..<16 {
            DispatchQueue.global().async(group: group) { _ = try? reg.create(name: "box-\(i)") }
        }
        group.wait()
        #expect(try reg.list().count == 16)
    }

    @Test func concurrentTransitionsOfDifferentVmsAreAllKept() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        for i in 0..<8 { _ = try reg.create(name: "vm-\(i)") }
        let group = DispatchGroup()
        for i in 0..<8 {
            DispatchQueue.global().async(group: group) { _ = try? reg.start("vm-\(i)") }
        }
        group.wait()
        #expect(try reg.list().allSatisfy { $0.state == .running })
    }
}
