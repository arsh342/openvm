// AppDelegate — launch, the menu-bar icon, what the Dock icon does, and quitting.
import AppKit
import Combine
import OpenVMCore
import OpenVMHost
import UniformTypeIdentifiers

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
    private var appSettings: AppSettingsWindowController?
    private let settings = AppSettingsModel.shared
    private var subscriptions: [AnyCancellable] = []
    private var subscription: AnyCancellable?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowRegistry.shared.context = context
        let machine = makeMachineMenus()
        self.machine = machine
        let menu = AppMenu(
            model: model, machine: machine, showLibrary: { [weak self] in self?.showLibrary() },
            newVM: { [weak self] in self?.showWizard() },
            openInstaller: { [weak self] in self?.openInstallerFile() },
            showSettings: { [weak self] in self?.showAppSettings() },
            openVM: { [weak self] vm in self?.openWindow(vm) })
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
            // An installer file dropped on the Dock icon, or opened with openVM, starts a new VM from it.
            if url.isFileURL {
                if url.pathExtension.lowercased() == "iso" { showWizard(.file(url)) }
                continue
            }
            guard let reference = vmReference(from: url) else { continue }
            Task { await openWindow(for: reference) }
        }
    }

    /// Opens a VM's window by name or uuid: from a link, and from the wizard as soon as it has made the VM.
    private func openWindow(for reference: String) async {
        guard let vm = await model.find(reference) else { return }
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
                model: model, context: context, newVM: { [weak self] start in self?.showWizard(start) })
        library = controller
        NSApp.setActivationPolicy(.regular)  // a window needs the Dock icon back
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// The creation wizard. One at a time: a second request brings the open one forward, and hands it
    /// the file or system that came with the request unless it is already installing.
    private func showWizard(_ start: NewVMStart = .gallery) {
        if let wizard, wizard.window?.isVisible == true {
            wizard.showWindow(nil)
            NSApp.activate()
            wizard.begin(start)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let controller = CreateWizardWindowController(
            transport: model.transport, existingNames: model.vms.map(\.name),
            openWindow: { [weak self] name in Task { await self?.openWindow(for: name) } })
        wizard = controller
        controller.showWindow(nil)
        NSApp.activate()
        controller.begin(start)
    }

    /// File ▸ Open Installer File…: choose an installer, and make a VM from it.
    private func openInstallerFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let iso = UTType(filenameExtension: "iso") { panel.allowedContentTypes = [iso] }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose an installer file: Windows 11 for Arm, or a Linux made for Arm."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showWizard(.file(url))
    }

    private func showSettings(_ vm: VmSummary) {
        NSApp.setActivationPolicy(.regular)
        SettingsWindows.shared.show(vm, transport: model.transport)
    }

    private func openWindow(_ vm: VmSummary) {
        NSApp.setActivationPolicy(.regular)
        WindowRegistry.shared.show(vm, model: model)
    }

    /// openVM's own settings (openVM ▸ Settings…).
    private func showAppSettings() {
        let controller = appSettings ?? AppSettingsWindowController(model: settings, vms: model)
        appSettings = controller
        NSApp.setActivationPolicy(.regular)
        controller.showWindow(nil)
        NSApp.activate()
    }

    // MARK: commands on a VM

    /// What every command on a VM is carried out with, wherever it was chosen.
    private var context: VMCommandContext {
        VMCommandContext(
            model: model,
            openWindow: { [weak self] vm in self?.openWindow(vm) },
            showSettings: { [weak self] vm in self?.showSettings(vm) },
            shareFolder: { [weak self] vm in
                self?.openWindow(vm)
                WindowRegistry.shared.controller(for: vm.uuid)?.shareFolder()
            },
            confirmDelete: { [weak self] vm in self?.confirmDelete(vm) })
    }

    /// Asks before a VM is deleted, naming the disk that is lost, as a sheet on the window in front.
    private func confirmDelete(_ vm: VmSummary) {
        let text = VMRowLogic.deleteConfirmation(for: vm)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.message
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let delete = { [model] in Task { await model.delete(vm) } }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { _ = MainActor.assumeIsolated { delete() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            _ = delete()
        }
    }

    // MARK: the menu-bar icon

    private func installStatusMenu() {
        if let machine { statusMenu = StatusMenuController(menus: machine, settings: settings) }
        // Turning the icon off or on changes whether the Dock icon has to stay.
        subscriptions.append(
            settings.$showsMenuBarIcon.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshActivationPolicy() } }
            })
    }

    private func makeMachineMenus() -> MachineMenus {
        MachineMenus(
            model: model, context: context,
            actions: MachineMenuActions(
                showLibrary: { [weak self] in self?.showLibrary() },
                newVM: { [weak self] in self?.showWizard() },
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
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
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
        let open = NSApp.windows.filter {
            $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized)
        }.count
        let live = model.vms.contains {
            $0.state == .running || $0.state == .suspended || $0.activity == "start"
        }
        let wanted = activationPolicy(
            openWindows: open, anyGuestLive: live, menuBarIcon: settings.showsMenuBarIcon)
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    // MARK: quitting

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let downloading = model.downloading.map(\.name)
        guard
            case .confirm(let running, let installing, let dropping) = quitDecision(
                model.vms, downloading: downloading)
        else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit openVM?"
        alert.informativeText = quitMessage(
            running: running, installing: installing, dropping: dropping, downloading: downloading)
        alert.addButton(withTitle: quitButtonTitle(running: running, installing: installing))
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
