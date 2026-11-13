// VMRowLogic — what the library says about a VM: its system, its size, and what deleting it loses.
// Plain functions of a VM's summary, so they can be tested without a window. What a VM can be asked
// to do, and its status, are in VMCommand.
import Foundation
import OpenVMCore

enum VMRowLogic {
    /// What a VM runs, in a word or two. An Alpine guest is one an earlier openVM made, and it says so,
    /// because it can no longer be started.
    static func system(for vm: VmSummary) -> String {
        switch vm.bootMode {
        case .windows: return "Windows"
        case .linuxISO: return "Linux"
        case .alpine: return "Alpine Linux (no longer supported)"
        }
    }

    /// What it runs, as the library's table says it: the name given when it was made ("Ubuntu 26.04"),
    /// else the kind of system.
    static func systemName(for vm: VmSummary) -> String { vm.systemName ?? system(for: vm) }

    /// When something happened, for a table cell: "Today, 10:42", "12 Nov 2026", or "Never".
    static func date(_ date: Date?, never: String = "Never") -> String {
        guard let date else { return never }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// "Linux · 4 CPUs · 4 GB memory · 32 GB disk"
    static func subtitle(for vm: VmSummary) -> String {
        var parts = [system(for: vm)]
        parts.append(vm.cpus == 1 ? "1 CPU" : "\(vm.cpus) CPUs")
        parts.append("\(memory(vm.memoryMB)) memory")
        if let disk = vm.diskBytes { parts.append("\(size(disk)) disk") }
        return parts.joined(separator: " · ")
    }

    /// What the confirmation says. It names the disk, because the disk is what is lost.
    static func deleteConfirmation(for vm: VmSummary) -> (title: String, message: String) {
        let disk = vm.diskBytes.map { " (\(size($0)))" } ?? ""
        return (
            "Delete “\(vm.name)”?",
            "This permanently deletes \(vm.name) and its virtual disk\(disk). This cannot be undone."
        )
    }

    static func memory(_ megabytes: Int) -> String {
        megabytes >= 1024 && megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    /// Binary units, because disks are made in MiB: 32768 MiB reads as "32 GB", not "34.4 GB".
    static func size(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

extension VMRowLogic {
    /// The facts the library's detail pane lists for a VM, in order. Sharing switches are not repeated
    /// here: Settings… has them.
    static func details(for vm: VmSummary) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = [
            ("System", systemName(for: vm)),
            ("CPUs", "\(vm.cpus)"),
            ("Memory", memory(vm.memoryMB)),
        ]
        if let disk = vm.diskBytes { rows.append(("Disk", "\(size(disk)) at most")) }
        if let used = vm.diskUsedBytes { rows.append(("Size on Disk", used == 0 ? "Empty" : size(used))) }
        if let created = vm.created { rows.append(("Created", date(created))) }
        rows.append(("Last Used", date(vm.lastStarted)))
        return rows
    }
}
