// VMWindowController — one VM's window: the guest's screen, and the keyboard and mouse
// going into it. The screen is Apple's VZVirtualMachineView, which needs the live
// machine in this process (that is why the app hosts the VMs).
//
// The window owns the guest's display size: when it changes, the guest is given a mode
// that makes its desktop exactly as large, in points, as the window.
import AppKit
import OpenVMCore
import OpenVMHost
import Virtualization

@MainActor
final class VMWindowController: NSWindowController, NSWindowDelegate {
    private let machineView = VZVirtualMachineView()
    private let cover = VMStatusView()
    private let transport: any HostTransport
    private let onStart: (VmSummary) -> Void
    private let resizer: ResizeCoalescer
    private(set) var vm: VmSummary
    private(set) var state: VMWindowState = .stopped

    init(vm: VmSummary, transport: any HostTransport, onStart: @escaping (VmSummary) -> Void) {
        self.vm = vm
        self.transport = transport
        self.onStart = onStart
        let uuid = vm.uuid
        self.resizer = ResizeCoalescer { mode in
            await Self.applyDisplay(mode, to: uuid, over: transport)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // the controller outlives its window
        window.collectionBehavior = [.fullScreenPrimary]
        // A saved frame wins; otherwise centre it. Left alone, AppKit places the window at
        // a default origin and squeezes it to fit the screen's right edge (measured:
        // 1249 wide for a 1280 request).
        let frameName = "vm-window-\(vm.uuid)"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
        window.delegate = self
        updateMinimumSize()

        // The display size is set by the host's display op, not by the view: the guest's
        // agent has to adopt a mode, which the view cannot do.
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
        let before = state
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
        // A guest that has just become ready (first boot, or back from a pause) is sized to
        // the window. This is also what gives a first Windows boot, which comes up at
        // 1024x768, its right size.
        if state == .running, before != .running {
            Task { await resizer.forget() }
            fitGuestToWindow()
        }
    }

    private func title(for state: VMWindowState) -> String {
        switch state {
        case .stopped: return "\(vm.name) — Stopped"
        case .busy(let what): return "\(vm.name) — \(what)"
        case .paused: return "\(vm.name) — Paused"
        case .running, .failed: return vm.name
        }
    }

    // MARK: size

    /// The smallest window is 640 x 480 pixels at the current backing scale, which is the
    /// smallest desktop the guest agents accept.
    private func updateMinimumSize() {
        guard let window else { return }
        let backing = max(1, window.backingScaleFactor)
        window.contentMinSize = NSSize(width: 640 / backing, height: 480 / backing)
    }

    /// Asks for the guest to match the window. Only a running guest has an agent to take it;
    /// a booting one is sized when it becomes ready. Between resizes the view scales the
    /// last frame, so a window dragged larger never shows a failure.
    private func fitGuestToWindow() {
        guard state == .running, let window else { return }
        let mode = DisplayFit.mode(pointSize: machineView.bounds.size, backingScale: window.backingScaleFactor)
        Task { await resizer.request(mode) }
    }

    /// Sends a mode to the guest. A refused scale (Windows caps it by desktop size) steps
    /// down to the highest one the guest allows; anything else fails once.
    private nonisolated static func applyDisplay(
        _ mode: DisplayFit.Mode, to uuid: String, over transport: any HostTransport
    ) async -> Bool {
        var failure = ""
        for scale in DisplayFit.scalesToTry(mode.scale) {
            do {
                _ = try await transport.send(
                    "display",
                    [
                        ("id", .text(uuid)), ("width", .uint(mode.width)), ("height", .uint(mode.height)),
                        ("scale", .uint(scale)),
                    ])
                return true
            } catch {
                failure = "\(error)"
                if !DisplayFit.shouldStepDown(after: failure) { break }
            }
        }
        FileHandle.standardError.write(
            Data("openvm: could not set the guest display to \(mode.width)x\(mode.height): \(failure)\n".utf8))
        return false
    }

    func windowDidResize(_ notification: Notification) { fitGuestToWindow() }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateMinimumSize()
        fitGuestToWindow()
    }

    // MARK: full screen takes the system's hot keys for the guest

    func windowDidEnterFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = true }
    func windowDidExitFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = false }
}
