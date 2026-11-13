// LibraryNav — what the library is showing: which group, which VM is selected, the search text and the
// table's sort order. It lives here, not in the views, so it can be tested without a window and the
// views need no state of their own.
import Combine
import Foundation
import OpenVMCore

/// The groups in the library's sidebar.
enum LibraryGroup: String, Hashable, CaseIterable {
    case all, running
    /// The installers openVM downloaded, and downloads in flight.
    case installers

    /// The groups that list VMs.
    static let machines: [LibraryGroup] = [.all, .running]

    var title: String {
        switch self {
        case .all: return "All"
        case .running: return "Running"
        case .installers: return "Downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .running: return "play.circle"
        case .installers: return "arrow.down.circle"
        }
    }
}

/// One row of the library's table: a VM with the values its columns show and sort by.
nonisolated struct VMTableRow: Identifiable, Equatable, Sendable {
    let vm: VmSummary
    var id: String { vm.uuid }
    let name: String
    let system: String
    /// Sorting by status puts what is live first: running, busy, paused, stopped.
    let statusRank: Int
    /// A VM never started sorts as the oldest.
    let lastUsed: Date
    let sizeOnDisk: UInt64

    @MainActor
    init(_ vm: VmSummary) {
        self.vm = vm
        name = vm.name
        system = VMRowLogic.systemName(for: vm)
        if vm.installing || vm.activity != nil {
            statusRank = 1
        } else {
            switch vm.state {
            case .running: statusRank = 0
            case .starting, .stopping: statusRank = 1
            case .suspended: statusRank = 2
            case .stopped: statusRank = 3
            }
        }
        lastUsed = vm.lastStarted ?? .distantPast
        sizeOnDisk = vm.diskUsedBytes ?? 0
    }
}

@MainActor
final class LibraryNav: ObservableObject {
    @Published var group: LibraryGroup? = .all
    /// The selected VM's uuid. The menu bar's commands act on it while the library is in front.
    @Published var selection: String?
    @Published var search = ""
    @Published var sortOrder: [KeyPathComparator<VMTableRow>] = [KeyPathComparator(\VMTableRow.name)]
}

extension LibraryNav {
    /// The VMs a group lists. Running means anything that holds a live guest: running, paused or booting.
    nonisolated static func members(_ vms: [VmSummary], of group: LibraryGroup) -> [VmSummary] {
        switch group {
        case .all, .installers: return vms
        case .running:
            return vms.filter { $0.state == .running || $0.state == .suspended || $0.activity == "start" }
        }
    }

    /// The VMs whose names contain the search text, ignoring case and surrounding spaces.
    nonisolated static func visible(_ vms: [VmSummary], search: String) -> [VmSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return vms }
        return vms.filter { $0.name.lowercased().contains(needle) }
    }

    /// The table's rows: the group's VMs that match the search, in the chosen order.
    static func rows(
        _ vms: [VmSummary], group: LibraryGroup, search: String, sortOrder: [KeyPathComparator<VMTableRow>]
    ) -> [VMTableRow] {
        visible(members(vms, of: group), search: search).map { VMTableRow($0) }.sorted(using: sortOrder)
    }

    /// The VM a selection names, if it still exists (it may have been deleted from the command line).
    nonisolated static func selectedVM(_ selection: String?, in vms: [VmSummary]) -> VmSummary? {
        guard let selection else { return nil }
        return vms.first { $0.uuid == selection }
    }

    /// What to select when the list changes: the current selection while it exists, else the first VM,
    /// so a command in the menu bar has something to act on.
    nonisolated static func resolve(_ selection: String?, in vms: [VmSummary]) -> String? {
        selectedVM(selection, in: vms)?.uuid ?? vms.first?.uuid
    }
}
