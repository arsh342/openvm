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
    private let toolbar = VMToolbar()
    /// The same model the list and the menus use, so every button acts the way theirs do.
    private let model: VMListModel
    private let showSettings: (VmSummary) -> Void
    private let resizer: ResizeCoalescer
    private let clipboard: ClipboardSync
    private(set) var vm: VmSummary
    private(set) var state: VMWindowState = .stopped

    init(vm: VmSummary, model: VMListModel, showSettings: @escaping (VmSummary) -> Void) {
        self.vm = vm
        self.model = model
        self.showSettings = showSettings
        let uuid = vm.uuid
        let transport = model.transport
        self.resizer = ResizeCoalescer { mode in
            await Self.applyDisplay(mode, to: uuid, over: transport)
        }
        let sync = ClipboardSync(vm: vm, transport: transport, pasteboard: MacPasteboard())
        self.clipboard = sync
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
        sync.onNotice = { [weak window] notice in window?.subtitle = notice ?? "" }
        updateMinimumSize()

        // The display size is set by the host's display op, not by the view: the guest's
        // agent has to adopt a mode, which the view cannot do.
        machineView.automaticallyReconfiguresDisplay = false
        machineView.capturesSystemKeys = false

        // Both fill the window, pinned with constraints. The machine view is built for Auto
        // Layout (its autoresizing-mask translation is off), so it is not left to follow the
        // window by autoresizing alone: in the running app its size stayed at the first
        // window's while the window around it grew (measured).
        let container = NSView(frame: window.contentLayoutRect)
        for view in [machineView, cover] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container

        wireToolbar()
        window.toolbar = toolbar.toolbar
        window.toolbarStyle = .unified
        update(vm)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: toolbar

    private func wireToolbar() {
        toolbar.onPower = { [weak self] button in
            guard let self else { return }
            switch button {
            case .start: Task { await self.model.start(self.vm) }
            // Shutting down asks the guest to stop, as the list's Stop does. Cancel stops a boot.
            case .shutDown, .cancel: Task { await self.model.stop(self.vm) }
            case .disabled: break
            }
        }
        toolbar.onPause = { [weak self] button in
            guard let self else { return }
            switch button {
            case .pause: Task { await self.model.suspend(self.vm) }
            case .resume: Task { await self.model.resume(self.vm) }
            case .disabled: break
            }
        }
        toolbar.onFullScreen = { [weak self] in self?.window?.toggleFullScreen(nil) }
        toolbar.onShareFolder = { [weak self] in self?.shareFolder() }
        toolbar.onClipboard = { [weak self] on in
            guard let self else { return }
            Task { await self.model.setClipboardSync(self.vm, on) }
        }
        toolbar.onSettings = { [weak self] in
            guard let self else { return }
            self.showSettings(self.vm)
        }
    }

    /// Shares one folder with the guest. The guest can change what is in it, so the panel
    /// says so before anything is shared.
    private func shareFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Choose a folder to share with \(vm.name). The guest can read and change what is in it."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.model.transport.send(
                        "share-add", [("id", .text(self.vm.uuid)), ("hostPath", .text(url.path))])
                } catch {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Could not share the folder"
                    alert.informativeText = "\(error)"
                    alert.beginSheetModal(for: window) { _ in }
                }
            }
        }
    }

    /// Called whenever the host's list changes.
    func update(_ vm: VmSummary) {
        self.vm = vm
        let before = state
        clipboard.setEnabled(vm.clipboardSync)
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
            Task { await self.model.start(self.vm) }
        }
        toolbar.update(VMToolbarLogic.state(for: vm))
        window?.title = title(for: state)
        if state == .running, window?.firstResponder !== machineView { window?.makeFirstResponder(machineView) }
        // A guest that has just become ready (first boot, or back from a pause) is sized to
        // the window. This is also what gives a first Windows boot, which comes up at
        // 1024x768, its right size.
        if state == .running, before != .running {
            Task { await resizer.forget() }
            fitGuestToWindow()
            // A window already in front when the guest comes up has no focus change to trigger a push.
            if window?.isKeyWindow == true { Task { await clipboard.focusGained() } }
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

    func windowDidResize(_ notification: Notification) {
        fitGuestToWindow()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        updateMinimumSize()
        fitGuestToWindow()
    }

    // MARK: clipboard follows focus

    /// Only a running guest has an agent to talk to; a booting or paused one is skipped.
    func windowDidBecomeKey(_ notification: Notification) {
        guard state == .running else { return }
        Task { await clipboard.focusGained() }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard state == .running else { return }
        Task { await clipboard.focusLost() }
    }

    // MARK: full screen takes the system's hot keys for the guest

    func windowDidEnterFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = true }
    func windowDidExitFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = false }
}
