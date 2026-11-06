// AppDelegate — launch: start the host, and say so plainly if it cannot start.
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
    private var subscription: AnyCancellable?

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
        WindowRegistry.shared.show(vm, transport: model.transport) { [model] vm in Task { await model.start(vm) } }
    }

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
        subscription = model.$vms.sink { WindowRegistry.shared.update($0) }
        model.begin()
        showLibrary()
    }

    /// The window that lists every VM. Opened at launch, from the Window menu, and by a click
    /// on the Dock icon when no window is open.
    private func showLibrary() {
        let controller =
            library
            ?? LibraryWindowController(model: model) { [weak self] vm in
                guard let self else { return }
                WindowRegistry.shared.show(vm, transport: self.model.transport) { [model] vm in
                    Task { await model.start(vm) }
                }
            }
        library = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }
}
