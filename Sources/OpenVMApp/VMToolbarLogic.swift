// VMToolbarLogic — which toolbar buttons are live for a VM, and what they say. A plain
// function of the VM's summary, so every state can be tested without a window.
import OpenVMCore

enum PowerButton: Equatable {
    case start, shutDown, cancel, disabled

    var title: String {
        switch self {
        case .start: return "Start"
        case .shutDown: return "Shut Down"
        case .cancel: return "Cancel Start"
        case .disabled: return "Power"
        }
    }

    var symbol: String {
        switch self {
        case .start: return "play.fill"
        case .shutDown, .disabled: return "power"
        case .cancel: return "xmark.circle"
        }
    }
}

enum PauseButton: Equatable {
    case pause, resume, disabled

    var title: String { self == .resume ? "Resume" : "Pause" }
    var symbol: String { self == .resume ? "play.fill" : "pause.fill" }
}

struct ToolbarState: Equatable {
    let power: PowerButton
    let pause: PauseButton
    let fullScreenEnabled: Bool
    /// Whether this VM shares its clipboard with the Mac (the toolbar button shows it pressed).
    var clipboardSync = true
}

enum VMToolbarLogic {
    static func state(for vm: VmSummary) -> ToolbarState {
        var state = base(for: vm)
        state.clipboardSync = vm.clipboardSync
        return state
    }

    private static func base(for vm: VmSummary) -> ToolbarState {
        if let activity = vm.activity {
            // A boot in progress can be cancelled; nothing else can be done to a VM the host is busy with.
            return ToolbarState(
                power: activity == "start" ? .cancel : .disabled, pause: .disabled,
                fullScreenEnabled: vm.state != .stopped || activity == "start")
        }
        switch vm.state {
        case .stopped:
            return ToolbarState(power: .start, pause: .disabled, fullScreenEnabled: false)
        case .running:
            return ToolbarState(power: .shutDown, pause: .pause, fullScreenEnabled: true)
        case .suspended:
            return ToolbarState(power: .shutDown, pause: .resume, fullScreenEnabled: true)
        case .starting, .stopping:
            return ToolbarState(power: .disabled, pause: .disabled, fullScreenEnabled: false)
        }
    }
}
