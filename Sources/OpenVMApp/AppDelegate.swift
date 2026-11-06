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
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = AppMenu(model: model) { [weak self] in self?.showLibrary() }
        self.menu = menu
        NSApp.mainMenu = menu.build()
        do {
            try OpenVMHost.start()
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
            ?? LibraryWindowController(model: model) { [weak self] vm in self?.openWindow(vm) }
        library = controller
        NSApp.setActivationPolicy(.regular)  // a window needs the Dock icon back
        controller.showWindow(nil)
        NSApp.activate()
    }

    private func openWindow(_ vm: VmSummary) {
        NSApp.setActivationPolicy(.regular)
        WindowRegistry.shared.show(vm, transport: model.transport) { [model] vm in Task { await model.start(vm) } }
    }

    // MARK: the menu-bar icon

    private func installStatusMenu() {
        statusMenu = StatusMenuController(
            model: model,
            act: { [weak self] action, vm in self?.perform(action, on: vm) },
            showLibrary: { [weak self] in self?.showLibrary() },
            quit: { NSApp.terminate(nil) })
    }

    private func perform(_ action: VMAction, on vm: VmSummary) {
        switch action {
        case .start:
            Task { await model.start(vm) }
            openWindow(vm)
        case .resume: Task { await model.resume(vm) }
        case .open: openWindow(vm)
        case .pause, .stop, .delete: break  // the popover offers only the obvious action
        }
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
