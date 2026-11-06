// AppDelegate — launch, the menu-bar icon, what the Dock icon does, and quitting.
import AppKit
import Combine
import OpenVMCore
import OpenVMHost

/// What to tell a person when the host could not start. Another host on the same
/// home (the app, or the headless openvmd) is the usual reason.
func hostStartFailureMessage(_ error: Error) -> String {
    if let pid = OpenVMHost.holderPid(of: error) {
        return "Another openVM host (process \(pid)) is already running. Quit it to use the app."
    }
    return "openVM could not start: \(OpenVMHost.startFailure(error))"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The windows and menus talk to the host through its socket, like openvmctl does.
    private let model = VMListModel(transport: DaemonClient())
    private var menu: AppMenu?
    private var library: LibraryWindowController?
    private var statusMenu: StatusMenuController?
    private var machine: MachineMenus?
    private var wizard: CreateWizardWindowController?
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let machine = makeMachineMenus()
        self.machine = machine
        let menu = AppMenu(
            model: model, machine: machine, showLibrary: { [weak self] in self?.showLibrary() },
            newVM: { [weak self] in self?.showWizard() })
        self.menu = menu
        NSApp.mainMenu = menu.build()
        do {
            try OpenVMHost.start()
            OpenVMHost.setOutboxHandler { receipt in
                Task { @MainActor in WindowRegistry.shared.received(receipt) }
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "openVM cannot start"
            alert.informativeText = hostStartFailureMessage(error)
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        model.begin()
        showLibrary()
        installStatusMenu()
        watchWindows()
    }

    // MARK: links and the Dock

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let reference = vmReference(from: url) else { continue }
            Task { await openWindow(for: reference) }
        }
    }

    /// A link may arrive before the first poll has filled the list.
    private func openWindow(for reference: String) async {
        if model.vms.isEmpty { await model.refresh() }
        guard let vm = model.vms.first(where: { $0.name == reference || $0.uuid.lowercased() == reference.lowercased() })
        else { return }
        openWindow(vm)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }

    // MARK: windows

    /// The window that lists every VM. Opened at launch, from the Window menu, from the
    /// menu-bar icon, and by a click on the Dock icon when no window is open.
    private func showLibrary() {
        let controller =
            library
            ?? LibraryWindowController(
                model: model, open: { [weak self] vm in self?.openWindow(vm) },
                settings: { [weak self] vm in self?.showSettings(vm) },
                newVM: { [weak self] in self?.showWizard() })
        library = controller
        NSApp.setActivationPolicy(.regular)  // a window needs the Dock icon back
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// The creation wizard. One at a time: a second request brings the open one forward.
    private func showWizard() {
        if let wizard, wizard.window?.isVisible == true {
            wizard.showWindow(nil)
            NSApp.activate()
            return
        }
        NSApp.setActivationPolicy(.regular)
        let controller = CreateWizardWindowController(
            transport: model.transport, existingNames: model.vms.map(\.name),
            openWindow: { [weak self] name in Task { await self?.openWindow(for: name) } })
        wizard = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    private func showSettings(_ vm: VmSummary) {
        NSApp.setActivationPolicy(.regular)
        SettingsWindows.shared.show(vm, transport: model.transport)
    }

    private func openWindow(_ vm: VmSummary) {
        NSApp.setActivationPolicy(.regular)
        WindowRegistry.shared.show(vm, model: model)
    }

    // MARK: the menu-bar icon

    private func installStatusMenu() {
        if let machine { statusMenu = StatusMenuController(menus: machine) }
    }

    private func makeMachineMenus() -> MachineMenus {
        MachineMenus(
            model: model,
            actions: MachineMenuActions(
                openWindow: { [weak self] vm in self?.openWindow(vm) },
                showSettings: { [weak self] vm in self?.showSettings(vm) },
                showLibrary: { [weak self] in self?.showLibrary() },
                newVM: { [weak self] in self?.showWizard() },
                toggleFullScreen: { [weak self] vm in
                    self?.openWindow(vm)
                    WindowRegistry.shared.controller(for: vm.uuid)?.machineFullScreen(nil)
                },
                shareFolder: { [weak self] vm in
                    self?.openWindow(vm)
                    WindowRegistry.shared.controller(for: vm.uuid)?.machineShareFolder(nil)
                },
                displayChanged: { vm in WindowRegistry.shared.controller(for: vm.uuid)?.refit() },
                isFullScreen: { uuid in WindowRegistry.shared.controller(for: uuid)?.isFullScreen ?? false },
                lastUsed: { WindowRegistry.shared.lastUsed },
                use: { uuid in WindowRegistry.shared.lastUsed = uuid }))
    }

    // MARK: the Dock icon

    /// With a window open the app is an ordinary app. With none open and a guest running it
    /// lives in the menu bar, and the icon there is the way back.
    private func watchWindows() {
        let names = [
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    // After the window has finished closing, not while it still counts as open.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshActivationPolicy() } }
                })
        }
        subscription = model.$vms.sink { [weak self] vms in
            WindowRegistry.shared.update(vms)
            self?.refreshActivationPolicy()
        }
    }

    private func refreshActivationPolicy() {
        let open = NSApp.windows.filter { $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }.count
        let live = model.vms.contains { $0.state == .running || $0.state == .suspended || $0.activity == "start" }
        let wanted = activationPolicy(openWindows: open, anyGuestLive: live)
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    // MARK: quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard case .confirm(let running, let installing, let dropping) = quitDecision(model.vms) else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit openVM?"
        alert.informativeText = quitMessage(running: running, installing: installing, dropping: dropping)
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        // Every guest is asked to shut down, in parallel, before the app goes: quitting with
        // them running would cut their power.
        Task {
            await OpenVMHost.stopAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
