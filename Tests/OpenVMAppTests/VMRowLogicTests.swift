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
        let row = CBOR.map([
            ("name", .text("w")), ("state", .text("running")), ("uuid", .text("u")), ("cpus", .uint(4)),
            ("memoryMB", .uint(8192)), ("bootMode", .text("windows")), ("diskBytes", .uint(64 << 30)),
            ("diskUsedBytes", .uint(21 << 30)), ("systemName", .text("Windows 11")),
        ])
        let rows = VMRowLogic.details(for: VmSummary(row: row)!)
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(byLabel["System"] == "Windows 11")
        #expect(byLabel["CPUs"] == "4")
        #expect(byLabel["Memory"] == "8 GB")
        #expect(byLabel["Disk"] == "64 GB at most")
        #expect(byLabel["Size on Disk"] == "21 GB")
        #expect(byLabel["Last Used"] == "Never")
    }
}
