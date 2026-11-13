// What the library says about a VM: its system and size, and what deleting it loses.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct VMRowLogicTests {
    private func vm(
        _ name: String = "w", bootMode: String = "linux-iso", cpus: UInt64 = 4, memoryMB: UInt64 = 4096,
        diskBytes: UInt64? = 32 << 30
    ) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text("stopped")), ("uuid", .text("u-\(name)")),
            ("cpus", .uint(cpus)), ("memoryMB", .uint(memoryMB)), ("bootMode", .text(bootMode)),
        ]
        if let diskBytes { fields.append(("diskBytes", .uint(diskBytes))) }
        return VmSummary(row: .map(fields))!
    }

    @Test func subtitleDescribesTheMachine() {
        #expect(
            VMRowLogic.subtitle(for: vm(bootMode: "linux-iso")) == "Linux · 4 CPUs · 4 GB memory · 32 GB disk")
        // one an earlier openVM made says that it cannot run any more
        #expect(VMRowLogic.subtitle(for: vm(bootMode: "linux")).hasPrefix("Alpine Linux (no longer supported) · "))
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

    @Test func detailsListWhatTheVmIs() {
        let vm = VmSummary(row: FakeTransport.row("w", state: "running", bootMode: "windows", cpus: 4, memoryMB: 8192, clipboardSync: false, outbox: true))!
        let rows = VMRowLogic.details(for: vm)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["System"] == "Windows")
        #expect(byLabel["CPUs"] == "4")
        #expect(byLabel["Memory"] == "8 GB")
        #expect(byLabel["Clipboard sharing"] == "Off")
        #expect(byLabel["Receiving files from the VM"] == "On")
    }
}
