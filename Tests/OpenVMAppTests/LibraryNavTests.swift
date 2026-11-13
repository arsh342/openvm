// What the library shows: the VMs of a group, filtered by the search, in the table's order; and which VM
// the menu bar's commands act on while the library is in front.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
struct LibraryNavTests {
    private func vm(
        _ name: String, state: String = "stopped", activity: String? = nil, started: String? = nil, used: UInt64? = nil,
        system: String? = nil, bootMode: String = "linux-iso"
    ) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text(state)), ("uuid", .text("uuid-\(name)")), ("cpus", .uint(4)),
            ("memoryMB", .uint(4096)), ("bootMode", .text(bootMode)),
        ]
        if let activity { fields.append(("activity", .text(activity))) }
        if let started { fields.append(("lastStartedAt", .text(started))) }
        if let used { fields.append(("diskUsedBytes", .uint(used))) }
        if let system { fields.append(("systemName", .text(system))) }
        return VmSummary(row: .map(fields))!
    }

    private func names(
        _ vms: [VmSummary], group: LibraryGroup = .all, search: String = "",
        by order: [KeyPathComparator<VMTableRow>] = [KeyPathComparator(\VMTableRow.name)]
    ) -> [String] {
        LibraryNav.rows(vms, group: group, search: search, sortOrder: order).map(\.name)
    }

    @Test func searchFindsVmsByNamePartAndCase() {
        let all = [vm("Ubuntu-Lab"), vm("windows-11"), vm("scratch")]
        #expect(names(all) == ["scratch", "Ubuntu-Lab", "windows-11"])
        #expect(names(all, search: "WIN") == ["windows-11"])
        #expect(names(all, search: "  lab ") == ["Ubuntu-Lab"])
        #expect(names(all, search: "zzz").isEmpty)
    }

    /// Running means anything that holds a live guest: a paused one is in memory, and a booting one is
    /// live though its record still says stopped.
    @Test func theRunningGroupListsEveryLiveGuest() {
        let all = [vm("a", state: "running"), vm("b", state: "suspended"), vm("c"), vm("d", activity: "start")]
        #expect(names(all, group: .running) == ["a", "b", "d"])
        #expect(names(all, group: .all).count == 4)
    }

    @Test func aHeaderClickSortsByThatColumnEitherWay() {
        let all = [
            vm("b", state: "stopped", started: "2026-11-10T08:00:00Z", used: 30 << 30),
            vm("a", state: "running", started: "2026-11-12T08:00:00Z", used: 10 << 30),
            vm("c", state: "suspended", used: 20 << 30),
        ]
        #expect(names(all, by: [KeyPathComparator(\VMTableRow.name, order: .reverse)]) == ["c", "b", "a"])
        // By status: what is live comes first.
        #expect(names(all, by: [KeyPathComparator(\VMTableRow.statusRank)]) == ["a", "c", "b"])
        // By last used, newest first; one never started is the oldest.
        #expect(names(all, by: [KeyPathComparator(\VMTableRow.lastUsed, order: .reverse)]) == ["a", "b", "c"])
        #expect(names(all, by: [KeyPathComparator(\VMTableRow.sizeOnDisk)]) == ["a", "c", "b"])
    }

    @Test func theSystemColumnPrefersTheNameGivenAtCreation() {
        let rows = LibraryNav.rows(
            [vm("u", system: "Ubuntu 26.04"), vm("w", bootMode: "windows"), vm("x")], group: .all, search: "",
            sortOrder: [KeyPathComparator(\VMTableRow.name)])
        #expect(rows.map(\.system) == ["Ubuntu 26.04", "Windows", "Linux"])
    }

    // MARK: what the menu bar acts on

    @Test func theSelectedVmIsTheTarget() {
        #expect(LibraryNav.selectedVM("uuid-b", in: [vm("a"), vm("b")])?.name == "b")
    }

    @Test func withNothingSelectedOrAVmThatIsGoneThereIsNoTarget() {
        #expect(LibraryNav.selectedVM(nil, in: [vm("a")]) == nil)
        #expect(LibraryNav.selectedVM("uuid-gone", in: [vm("a")]) == nil)
    }

    /// The selection stays while its VM exists. When it goes (deleted from the command line, say), or
    /// nothing was selected yet, the first VM is selected.
    @Test func theSelectionFollowsTheList() {
        let all = [vm("a"), vm("b")]
        #expect(LibraryNav.resolve("uuid-b", in: all) == "uuid-b")
        #expect(LibraryNav.resolve("uuid-gone", in: all) == "uuid-a")
        #expect(LibraryNav.resolve(nil, in: all) == "uuid-a")
        #expect(LibraryNav.resolve("uuid-a", in: []) == nil)
    }
}
