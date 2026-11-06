// What a row in the VM list offers and says, for each state the host can report.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct VMRowLogicTests {
    private func vm(
        _ name: String = "w", state: String = "stopped", activity: String? = nil, bootMode: String = "linux",
        cpus: UInt64 = 4, memoryMB: UInt64 = 4096, diskBytes: UInt64? = 32 << 30
    ) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text(state)), ("uuid", .text("u-\(name)")),
            ("cpus", .uint(cpus)), ("memoryMB", .uint(memoryMB)), ("bootMode", .text(bootMode)),
        ]
        if let activity { fields.append(("activity", .text(activity))) }
        if let diskBytes { fields.append(("diskBytes", .uint(diskBytes))) }
        return VmSummary(row: .map(fields))!
    }

    @Test func eachStateOffersItsOwnActions() {
        #expect(VMRowLogic.actions(for: vm(state: "stopped")) == [.start, .delete])
        #expect(VMRowLogic.actions(for: vm(state: "running")) == [.open, .pause, .stop])
        #expect(VMRowLogic.actions(for: vm(state: "suspended")) == [.open, .resume, .stop])
    }

    /// While the host is doing something to a VM, the only safe thing left is to watch it.
    @Test func aBusyVmOffersOnlyToWatchIt() {
        for activity in ["start", "stop", "suspend", "resume", "delete"] {
            for state in ["stopped", "running", "suspended"] {
                #expect(VMRowLogic.actions(for: vm(state: state, activity: activity)) == [.open])
            }
        }
    }

    @Test func aLiveVmCannotBeDeleted() {
        for state in ["running", "suspended"] {
            #expect(!VMRowLogic.actions(for: vm(state: state)).contains(.delete))
        }
    }

    @Test func statusSaysWhatIsHappening() {
        #expect(VMRowLogic.statusText(for: vm(state: "stopped")) == "Stopped")
        #expect(VMRowLogic.statusText(for: vm(state: "running")) == "Running")
        #expect(VMRowLogic.statusText(for: vm(state: "suspended")) == "Paused")
        #expect(VMRowLogic.statusText(for: vm(state: "stopped", activity: "start")) == "Starting…")
        #expect(VMRowLogic.statusText(for: vm(state: "running", activity: "stop")) == "Shutting down…")
    }

    @Test func subtitleDescribesTheMachine() {
        #expect(
            VMRowLogic.subtitle(for: vm(bootMode: "linux")) == "Linux · 4 CPUs · 4 GB memory · 32 GB disk")
        #expect(
            VMRowLogic.subtitle(for: vm(bootMode: "windows", cpus: 1, memoryMB: 512, diskBytes: 64 << 30))
                == "Windows · 1 CPU · 512 MB memory · 64 GB disk")
        #expect(VMRowLogic.subtitle(for: vm(diskBytes: nil)) == "Linux · 4 CPUs · 4 GB memory")
    }

    @Test func deleteNamesTheVmAndTheDiskItRemoves() {
        let c = VMRowLogic.deleteConfirmation(for: vm("lab", diskBytes: 64 << 30))
        #expect(c.title == "Delete “lab”?")
        #expect(c.message.contains("lab"))
        #expect(c.message.contains("64 GB"))
        #expect(c.message.contains("cannot be undone"))
        #expect(!VMRowLogic.deleteConfirmation(for: vm("lab", diskBytes: nil)).message.contains("("))
    }
}

extension VMRowLogicTests {
    /// The menu-bar popover shows one button per VM: the thing a person most likely wants.
    @Test func eachVmHasOneObviousAction() {
        #expect(VMRowLogic.primaryAction(for: vm(state: "stopped")) == .start)
        #expect(VMRowLogic.primaryAction(for: vm(state: "running")) == .open)
        #expect(VMRowLogic.primaryAction(for: vm(state: "suspended")) == .resume)
        #expect(VMRowLogic.primaryAction(for: vm(state: "stopped", activity: "start")) == .open)
        #expect(VMRowLogic.primaryAction(for: vm(state: "running", activity: "stop")) == .open)
    }

    /// Delete is never the obvious action, however the list is arranged.
    @Test func theObviousActionIsNeverDelete() {
        for state in ["stopped", "running", "suspended"] {
            #expect(VMRowLogic.primaryAction(for: vm(state: state)) != .delete)
        }
    }
}
