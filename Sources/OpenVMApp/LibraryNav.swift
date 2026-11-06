// LibraryNav — which page of the library is showing, and which VMs the sidebar lists. Plain functions
// plus a small observable holder, so the choices can be tested without a window.
import Combine
import OpenVMCore

enum LibrarySelection: Hashable {
    case all
    case vm(String)
}

@MainActor
final class LibraryNav: ObservableObject {
    @Published var selection: LibrarySelection = .all
    @Published var search = ""
}


extension LibraryNav {
    /// The VMs whose names contain the search text, ignoring case and surrounding spaces.
    nonisolated static func visible(_ vms: [VmSummary], search: String) -> [VmSummary] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return vms }
        return vms.filter { $0.name.lowercased().contains(needle) }
    }

    /// A chosen VM that no longer exists (deleted from the CLI, say) gives way to the overview.
    nonisolated static func resolve(_ selection: LibrarySelection, in vms: [VmSummary]) -> LibrarySelection {
        if case .vm(let uuid) = selection, !vms.contains(where: { $0.uuid == uuid }) { return .all }
        return selection
    }
}
