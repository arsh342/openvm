// VMWindowState — what a VM's window shows, decided from what the host reports.
import OpenVMCore

enum VMWindowState: Equatable {
    case stopped
    /// The host is doing something to the VM; the text says what.
    case busy(String)
    case running
    case paused
    case failed(String)

    /// Whether the guest's screen is on show. A booting guest already draws, and a
    /// paused one keeps its last frame.
    var showsScreen: Bool {
        switch self {
        case .running, .busy, .paused: return true
        case .stopped, .failed: return false
        }
    }

    static func from(_ vm: VmSummary, hasMachine: Bool) -> VMWindowState {
        if let activity = vm.activity {
            return .busy(Self.label(for: activity))
        }
        switch vm.state {
        case .stopped: return .stopped
        case .starting: return .busy("Starting…")
        case .stopping: return .busy("Shutting down…")
        case .running:
            return hasMachine ? .running : .failed("The host has no live machine for this VM. Stop it and start it again.")
        case .suspended: return hasMachine ? .paused : .failed("The paused machine is gone. Stop the VM and start it again.")
        }
    }

    private static func label(for activity: String) -> String {
        switch activity {
        case "start": return "Starting…"
        case "stop": return "Shutting down…"
        case "suspend": return "Pausing…"
        case "resume": return "Resuming…"
        case "delete": return "Deleting…"
        default: return "Working…"
        }
    }
}
