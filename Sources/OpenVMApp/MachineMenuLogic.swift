// MachineMenuLogic — what the Machine menu offers for the VM whose window is in front.
// Plain functions of the VM's summary, so every state can be tested without a menu.
import OpenVMCore

enum MachineCommand: CaseIterable {
    case power, pause, fullScreen, shareFolder, clipboard, settings
}

struct MachineMenuItem: Equatable {
    var title: String
    var enabled: Bool
    var checked = false
}

enum MachineMenuLogic {
    /// `vm` is nil when no VM window is in front: then nothing is live.
    static func item(_ command: MachineCommand, for vm: VmSummary?) -> MachineMenuItem {
        guard let vm else { return MachineMenuItem(title: defaultTitle(command), enabled: false) }
        let state = VMToolbarLogic.state(for: vm)
        switch command {
        case .power: return MachineMenuItem(title: state.power.menuTitle, enabled: state.power != .disabled)
        case .pause: return MachineMenuItem(title: state.pause.title, enabled: state.pause != .disabled)
        case .fullScreen: return MachineMenuItem(title: "Enter Full Screen", enabled: state.fullScreenEnabled)
        case .shareFolder: return MachineMenuItem(title: "Share Folder…", enabled: true)
        case .clipboard: return MachineMenuItem(title: "Share Clipboard", enabled: true, checked: state.clipboardSync)
        case .settings: return MachineMenuItem(title: "Settings…", enabled: true)
        }
    }

    private static func defaultTitle(_ command: MachineCommand) -> String {
        switch command {
        case .power: return "Shut Down"
        case .pause: return "Pause"
        case .fullScreen: return "Enter Full Screen"
        case .shareFolder: return "Share Folder…"
        case .clipboard: return "Share Clipboard"
        case .settings: return "Settings…"
        }
    }
}

extension PowerButton {
    /// The menu says what the command does now, as the button used to.
    var menuTitle: String {
        switch self {
        case .disabled: return "Shut Down"
        default: return title
        }
    }
}
