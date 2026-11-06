// QuitPolicy — quitting the app stops every guest it hosts, so it says so first and names
// what would be lost. Closing a window never stops anything.
import AppKit
import OpenVMCore

enum QuitDecision: Equatable {
    case quitNow
    case confirm(running: [String], installing: [String], dropping: [String])
}

/// What quitting would do, from the host's list.
func quitDecision(_ vms: [VmSummary]) -> QuitDecision {
    // A paused guest is held in memory, not saved: quitting shuts it down. One that is booting
    // holds a live guest too, though its record still says stopped.
    let installing = vms.filter(\.installing).map(\.name)
    let running = vms.filter { vm in
        guard !vm.installing else { return false }
        return vm.state == .running || vm.state == .suspended || vm.activity == "start"
    }.map(\.name)
    let dropping = vms.filter(\.dropping).map(\.name)
    if running.isEmpty && installing.isEmpty && dropping.isEmpty { return .quitNow }
    return .confirm(running: running, installing: installing, dropping: dropping)
}

func quitMessage(running: [String], installing: [String], dropping: [String]) -> String {
    var lines: [String] = []
    if !running.isEmpty {
        lines.append("These virtual machines are running and will be shut down: \(running.joined(separator: ", ")).")
    }
    if !installing.isEmpty {
        lines.append(
            "A Windows install is in progress in \(installing.joined(separator: ", ")). Quitting stops it, and it starts over."
        )
    }
    if !dropping.isEmpty {
        lines.append("Files are still being copied into \(dropping.joined(separator: ", ")).")
    }
    return lines.joined(separator: "\n\n")
}

/// The Dock icon stays while there is a window to come back to. With none open and a guest
/// still running, the app lives in the menu bar only, so a running VM is not a Dock icon
/// with nothing to show.
func activationPolicy(openWindows: Int, anyGuestLive: Bool) -> NSApplication.ActivationPolicy {
    openWindows == 0 && anyGuestLive ? .accessory : .regular
}
