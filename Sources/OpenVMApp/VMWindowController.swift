// VMWindowController — one VM's window: the guest's screen, and the keyboard and mouse
// going into it. The screen is Apple's VZVirtualMachineView, which needs the live
// machine in this process (that is why the app hosts the VMs).
import AppKit
import OpenVMCore
import OpenVMHost
import Virtualization

@MainActor
final class VMWindowController: NSWindowController, NSWindowDelegate {
    private let machineView = VZVirtualMachineView()
    private let cover = VMStatusView()
    private let onStart: (VmSummary) -> Void
    private(set) var vm: VmSummary
    private(set) var state: VMWindowState = .stopped

    init(vm: VmSummary, onStart: @escaping (VmSummary) -> Void) {
        self.vm = vm
        self.onStart = onStart
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // the controller outlives its window
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 640, height: 480)
        // A saved frame wins; otherwise centre it. Left alone, AppKit places the window at
        // a default origin and squeezes it to fit the screen's right edge (measured:
        // 1249 wide for a 1280 request).
        let frameName = "vm-window-\(vm.uuid)"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
        window.delegate = self

        // The display size is set by the host's display op (Task 6), not by the view:
        // the guest's agent has to adopt a mode, which the view cannot do.
        machineView.automaticallyReconfiguresDisplay = false
        machineView.capturesSystemKeys = false

        let container = NSView(frame: window.contentLayoutRect)
        for view in [machineView, cover] as [NSView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        window.contentView = container
        update(vm)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called whenever the host's list changes.
    func update(_ vm: VmSummary) {
        self.vm = vm
        let machine = OpenVMHost.liveMachine(vm.uuid)
        state = VMWindowState.from(vm, hasMachine: machine != nil)
        if state.showsScreen {
            if machineView.virtualMachine !== machine { machineView.virtualMachine = machine }
        } else if machineView.virtualMachine != nil {
            machineView.virtualMachine = nil
        }
        machineView.isHidden = !state.showsScreen
        cover.show(state) { [weak self] in
            guard let self else { return }
            self.onStart(self.vm)
        }
        window?.title = title(for: state)
        if state == .running, window?.firstResponder !== machineView { window?.makeFirstResponder(machineView) }
    }

    private func title(for state: VMWindowState) -> String {
        switch state {
        case .stopped: return "\(vm.name) — Stopped"
        case .busy(let what): return "\(vm.name) — \(what)"
        case .paused: return "\(vm.name) — Paused"
        case .running, .failed: return vm.name
        }
    }

    // MARK: full screen takes the system's hot keys for the guest

    func windowDidEnterFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = true }
    func windowDidExitFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = false }
}
