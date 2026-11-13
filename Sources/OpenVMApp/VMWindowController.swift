// VMWindowController — one VM's window: the guest's screen, and the keyboard and mouse
// going into it. The screen is Apple's VZVirtualMachineView, which needs the live
// machine in this process (that is why the app hosts the VMs).
//
// The window owns the guest's display size: when it changes, the guest is given a mode
// that makes its desktop exactly as large, in points, as the window.
import AppKit
import OpenVMCore
import OpenVMHost
import SwiftUI
import Virtualization

@MainActor
final class VMWindowController: NSWindowController, NSWindowDelegate {
    private let machineView = DropMachineView()
    private let cover = VMStatusView()
    /// The same model the list and the menus use, so every button acts the way theirs do.
    private let model: VMListModel
    private let context: VMCommandContext
    private let resizer: ResizeCoalescer
    private let clipboard: ClipboardSync
    private let drops: DropSession
    private var thumbnailTimer: Timer?
    private(set) var vm: VmSummary
    private(set) var state: VMWindowState = .stopped
    private var stopNoticeShown = false

    init(vm: VmSummary, model: VMListModel, context: VMCommandContext) {
        self.vm = vm
        self.model = model
        self.context = context
        let uuid = vm.uuid
        let transport = model.transport
        self.resizer = ResizeCoalescer { mode in
            await Self.applyDisplay(mode, to: uuid, over: transport)
        }
        let sync = ClipboardSync(vm: vm, transport: transport, pasteboard: MacPasteboard())
        self.clipboard = sync
        let dropSession = DropSession(uuid: vm.uuid, name: vm.name, transport: transport)
        self.drops = dropSession
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
        // Dark around the guest, whatever the Mac's appearance: the guest is what the window is for.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
        window.delegate = self
        sync.onNotice = { [weak window] notice in window?.subtitle = notice ?? "" }
        wireDrops()
        machineView.guestHasKeyboard = { [weak self] in self?.guestHasKeyboard ?? false }
        installToolbar(window)
        startThumbnailTimer()
        updateMinimumSize()

        // The display size is set by the host's display op, not by the view: the guest's
        // agent has to adopt a mode, which the view cannot do.
        // A guest from an ISO has no agent to adopt a mode, so there the framework does it itself.
        machineView.automaticallyReconfiguresDisplay = !vm.bootMode.hasAgent
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

        update(vm)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A line under the title, for things that happen to the VM that the person did not ask for now.
    func showNotice(_ text: String) { window?.subtitle = text }

    // MARK: files dropped onto the screen

    private func wireDrops() {
        machineView.acceptsDrops = { [weak self] in
            guard let self else { return false }
            return self.state == .running && self.vm.bootMode.hasAgent && !self.drops.isRunning
        }
        machineView.onFiles = { [weak self] urls, cleanup in
            guard let self else { return }
            Task { @MainActor in
                self.window?.subtitle = "Copying to \(self.vm.name)\u{2019}s Desktop\u{2026}"
                await self.drops.begin(paths: urls.map(\.path))
                if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
                self.showDropResult()
            }
        }
    }

    private func showDropResult() {
        switch drops.state {
        case .finished(let names):
            window?.subtitle =
                names.count == 1
                ? "Copied 1 item to the Desktop" : "Copied \(names.count) items to the Desktop"
        case .failed(let why):
            window?.subtitle = ""
            if let window {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not copy the files"
                alert.informativeText = why
                alert.beginSheetModal(for: window) { _ in }
            }
        case .idle, .copying: break
        }
        drops.dismiss()
    }

    // MARK: the library's preview of this VM

    /// Takes a picture of the guest's screen for the library card. Skipped unless a guest is showing.
    /// A blank capture is dropped by the store, so a view that cannot be read leaves the old picture.
    func captureThumbnail() {
        guard state.showsScreen, !machineView.isHidden, machineView.bounds.width > 10,
            let rep = machineView.bitmapImageRepForCachingDisplay(in: machineView.bounds)
        else { return }
        machineView.cacheDisplay(in: machineView.bounds, to: rep)
        ThumbnailStore.shared.save(rep, for: vm.uuid)
    }

    /// While the window is up and the guest runs, refresh the picture now and then (the screen changes
    /// slowly enough that this costs nothing a person would notice).
    private func startThumbnailTimer() {
        thumbnailTimer?.invalidate()
        thumbnailTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true, self.state == .running else { return }
                self.captureThumbnail()
            }
        }
    }

    // MARK: commands, from the toolbar and the menu bar

    private func run(_ command: VMCommand) {
        Task { await command.perform(on: vm, in: context) }
    }

    /// A menu-bar command with this window in front is for this VM (VMCommandResponder).
    @objc func performVMCommand(_ sender: Any?) {
        if let command = VMCommand.from(sender) { run(command) }
    }

    /// Whether the guest's screen has the keyboard, so key combinations are the guest's (GuestKeys).
    private var guestHasKeyboard: Bool { state.showsScreen && window?.firstResponder === machineView }

    /// Shares one folder with the guest. The guest can change what is in it, so the panel
    /// says so before anything is shared.
    func shareFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message =
            "Choose a folder to share with \(vm.name). The guest can read and change what is in it."
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
        clipboard.setEnabled(vm.clipboardSync && vm.bootMode.hasAgent)
        let machine = OpenVMHost.liveMachine(vm.uuid)
        state = VMWindowState.from(vm, hasMachine: machine != nil)
        if state.showsScreen {
            if machineView.virtualMachine !== machine { machineView.virtualMachine = machine }
        } else if machineView.virtualMachine != nil {
            machineView.virtualMachine = nil
        }
        machineView.isHidden = !state.showsScreen
        window?.toolbar?.validateVisibleItems()
        cover.show(
            state, installerAttached: vm.installerAttached,
            onStart: { [weak self] in
                guard let self else { return }
                Task { await self.model.start(self.vm) }
            },
            onRemoveInstaller: { [weak self] in
                guard let self else { return }
                Task {
                    await self.model.ejectInstaller(self.vm)
                    guard self.model.lastError == nil, let fresh = self.model.vm(uuid: self.vm.uuid) else {
                        return
                    }
                    await self.model.start(fresh)
                }
            })
        showStopProgress()
        window?.title = title(for: state)
        if state == .running, window?.firstResponder !== machineView {
            window?.makeFirstResponder(machineView)
        }
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

    /// A guest without openVM's tools can only be asked to stop through the framework, and may take up to
    /// two minutes before it is forced off. The window says so instead of sitting silent.
    private func showStopProgress() {
        let asking = vm.activity == "stop" && !vm.bootMode.hasAgent
        if asking {
            window?.subtitle = "Asking \(vm.name) to shut down. This can take up to two minutes."
        } else if stopNoticeShown {
            window?.subtitle = ""
        }
        stopNoticeShown = asking
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
        guard vm.bootMode.hasAgent else { return }
        // Only a Windows guest has an agent. It gets the window's full size at the display's scale,
        // which needs a viogpudo with the mode-change fix (docs/gui-notes.md).
        let mode = DisplayFit.mode(
            pointSize: machineView.bounds.size, backingScale: window.backingScaleFactor)
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
            Data("openvm: could not set the guest display to \(mode.width)x\(mode.height): \(failure)\n".utf8)
        )
        return false
    }

    var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

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
        WindowRegistry.shared.lastUsed = vm.uuid
        guard state == .running else { return }
        Task { await clipboard.focusGained() }
    }

    func windowDidResignKey(_ notification: Notification) {
        captureThumbnail()
        guard state == .running else { return }
        Task { await clipboard.focusLost() }
    }

    // MARK: full screen takes the system's hot keys for the guest

    func windowWillClose(_ notification: Notification) { captureThumbnail() }

    /// In full screen the toolbar hides with the menu bar, so the guest has the whole screen; both come
    /// back when the pointer goes to the top edge.
    func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
    ) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideToolbar, .autoHideDock]
    }

    func windowDidEnterFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = true }
    func windowDidExitFullScreen(_ notification: Notification) { machineView.capturesSystemKeys = false }
}

extension VMWindowController: NSMenuItemValidation {
    /// Shows each Virtual Machine command as it is for this VM. Other items validate themselves.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == VMCommand.action { return VMCommand.validate(item, for: vm) }
        return true
    }
}

// MARK: toolbar

extension NSToolbarItem.Identifier {
    static let devices = NSToolbarItem.Identifier("devices")
}

extension VMWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    /// A standard toolbar: Start or Shut Down, Pause or Resume, a Devices menu and Settings, all from the
    /// one list of commands. Full screen stays on the green window button.
    func installToolbar(_ window: NSWindow) {
        let toolbar = NSToolbar(identifier: "vm-window")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        VMWindowToolbar.items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        VMWindowToolbar.items + [.command(.restart), .space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if identifier == .devices {
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Devices"
            item.paletteLabel = "Devices"
            item.toolTip = "Clipboard, files and folders shared with this virtual machine"
            item.image = NSImage(
                systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "Devices"
            )
            item.showsIndicator = true
            let menu = NSMenu(title: "Devices")
            // Each item is for this window's VM, whichever window is in front when the menu opens.
            for entry in VMCommand.items(VMCommand.devices, shortcuts: false) {
                if VMCommand.from(entry) != nil { entry.target = self }
                menu.addItem(entry)
            }
            item.menu = menu
            return item
        }
        guard let command = VMCommand(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.target = self
        item.action = VMCommand.action
        item.isBordered = true
        command.show(command.state(for: vm), on: item)
        return item
    }

    /// AppKit asks before it draws the toolbar: each command's item follows this VM.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let command = VMCommand.from(item) else { return true }
        let state = command.state(for: vm)
        command.show(state, on: item)
        return state.enabled
    }
}

/// What a VM window's toolbar holds, in order.
enum VMWindowToolbar {
    static let items: [NSToolbarItem.Identifier] = [
        .command(.power), .command(.pause), .devices, .flexibleSpace, .command(.settings),
    ]
}
