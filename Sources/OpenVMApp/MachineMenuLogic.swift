// MachineMenuLogic — what the menus offer for the current VM. Plain functions of the VM's summary, so
// every state can be tested without a menu.
import Foundation
import OpenVMCore

enum MachineCommand: CaseIterable {
    case power, restart, pause, fullScreen, reverseScrolling, retinaBest, retinaScaled, shareFolder, clipboard
    case outbox, ejectInstaller
    case settings
}

struct MachineMenuItem: Equatable {
    var title: String
    var enabled: Bool
    var checked = false
}

enum MachineMenuLogic {
    /// The VM the menus act on: the one last used, else one that is live, else the first.
    static func current(in vms: [VmSummary], lastUsed: String?) -> VmSummary? {
        vms.first { $0.uuid == lastUsed }
            ?? vms.first { $0.state == .running || $0.state == .suspended }
            ?? vms.first
    }

    /// `vm` is nil when there are no VMs: then nothing is live.
    static func item(
        _ command: MachineCommand, for vm: VmSummary?, scaled: Bool = false, fullScreen: Bool = false
    ) -> MachineMenuItem {
        guard let vm else { return MachineMenuItem(title: defaultTitle(command), enabled: false) }
        let state = VMToolbarLogic.state(for: vm)
        switch command {
        case .power: return MachineMenuItem(title: state.power.menuTitle, enabled: state.power != .disabled)
        case .restart:
            return MachineMenuItem(title: "Restart", enabled: vm.state == .running && vm.activity == nil)
        case .pause: return MachineMenuItem(title: state.pause.title, enabled: state.pause != .disabled)
        case .fullScreen:
            return MachineMenuItem(
                title: fullScreen ? "Exit Full Screen" : "Enter Full Screen", enabled: state.fullScreenEnabled)
        case .reverseScrolling:
            return MachineMenuItem(title: defaultTitle(command), enabled: true, checked: ScrollFlip.isReversed())
        // Only openVM's own Linux guest takes a size from these. A Windows guest is held at one width for
        // now (DisplayFit.windowsMode), and a guest from an ISO sizes itself through the framework.
        case .retinaBest:
            return MachineMenuItem(title: defaultTitle(command), enabled: vm.bootMode == .linux, checked: !scaled)
        case .retinaScaled:
            return MachineMenuItem(title: defaultTitle(command), enabled: vm.bootMode == .linux, checked: scaled)
        // These work through the guest agent, so a guest without one has nothing to offer.
        case .shareFolder: return MachineMenuItem(title: defaultTitle(command), enabled: vm.bootMode.hasAgent)
        // A guest from its own ISO can share it through the framework's Spice agent instead (next start).
        case .clipboard:
            let offered = vm.bootMode.hasAgent || vm.bootMode == .linuxISO
            return MachineMenuItem(title: defaultTitle(command), enabled: offered, checked: offered && vm.clipboardSync)
        case .outbox:
            return MachineMenuItem(
                title: defaultTitle(command), enabled: vm.bootMode.hasAgent, checked: vm.bootMode.hasAgent && vm.outbox)
        case .ejectInstaller:
            return MachineMenuItem(
                title: defaultTitle(command), enabled: vm.installerAttached && vm.state == .stopped && vm.activity == nil)
        case .settings: return MachineMenuItem(title: defaultTitle(command), enabled: true)
        }
    }

    /// The symbol beside a command, which follows what the command does now.
    static func symbol(_ command: MachineCommand, for vm: VmSummary?) -> String? {
        let state = vm.map(VMToolbarLogic.state(for:))
        switch command {
        case .power: return state?.power.symbol ?? "power"
        case .restart: return "arrow.clockwise"
        case .pause: return state?.pause.symbol ?? "pause.fill"
        case .settings: return "gearshape"
        default: return nil
        }
    }

    /// "Running · Linux · 4 CPUs · 4 GB memory": the current VM at a glance.
    static func summary(_ vm: VmSummary) -> String {
        VMRowLogic.statusText(for: vm) + " · " + VMRowLogic.subtitle(for: vm)
    }

    private static func defaultTitle(_ command: MachineCommand) -> String {
        switch command {
        case .power: return "Shut Down"
        case .restart: return "Restart"
        case .pause: return "Pause"
        case .fullScreen: return "Enter Full Screen"
        case .reverseScrolling: return "Reverse Scrolling"
        case .retinaBest: return "Best for Retina Display"
        case .retinaScaled: return "Scaled"
        case .shareFolder: return "Share Folder…"
        case .clipboard: return "Share Clipboard"
        case .outbox: return "Accept Files from the VM"
        case .ejectInstaller: return "Eject Installer ISO"
        case .settings: return "Settings…"
        }
    }
}

extension PowerButton {
    /// The menu says what the command does now.
    var menuTitle: String {
        switch self {
        case .disabled: return "Shut Down"
        default: return title
        }
    }
}

/// Per VM: draw at the display's full pixel density, or at one pixel per point (larger, softer, and
/// a much smaller guest screen).
struct DisplayPreference {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ uuid: String) -> String { "display-scaled-\(uuid)" }

    func isScaled(_ uuid: String) -> Bool { defaults.bool(forKey: key(uuid)) }
    func setScaled(_ scaled: Bool, for uuid: String) { defaults.set(scaled, forKey: key(uuid)) }

    /// The backing scale to fit the guest with.
    func backingScale(for uuid: String, actual: CGFloat) -> CGFloat { isScaled(uuid) ? 1 : actual }
}
