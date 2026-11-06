// VMRowLogic — what a row in the VM list offers and says. Plain functions of a VM's
// summary, so every state can be tested without a window.
import Foundation
import OpenVMCore

enum VMAction: Equatable {
    case open, start, pause, resume, stop, delete
}

enum VMRowLogic {
    /// The actions a row offers, in the order they are shown.
    static func actions(for vm: VmSummary) -> [VMAction] {
        // While the host is doing something to the VM the only safe thing left is to watch it.
        if vm.activity != nil { return [.open] }
        switch vm.state {
        case .stopped: return [.start, .delete]
        case .running: return [.open, .pause, .stop]
        case .suspended: return [.open, .resume, .stop]
        case .starting, .stopping: return [.open]
        }
    }

    static func statusText(for vm: VmSummary) -> String {
        if let activity = vm.activity { return VMWindowState.label(for: activity) }
        switch vm.state {
        case .stopped: return "Stopped"
        case .running: return "Running"
        case .suspended: return "Paused"
        case .starting: return "Starting…"
        case .stopping: return "Shutting down…"
        }
    }

    /// "Linux · 4 CPUs · 4 GB memory · 32 GB disk"
    static func subtitle(for vm: VmSummary) -> String {
        var parts = [vm.bootMode == .windows ? "Windows" : "Linux"]
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

    private static func memory(_ megabytes: Int) -> String {
        megabytes >= 1024 && megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    /// Binary units, because disks are made in MiB: 32768 MiB reads as "32 GB", not "34.4 GB".
    private static func size(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
