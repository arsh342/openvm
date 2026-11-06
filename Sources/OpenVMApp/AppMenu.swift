// AppMenu — the menu bar every Mac app has, plus the Machine menu that opens a VM's window.
import AppKit
import OpenVMCore

@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    private let model: VMListModel
    private let showLibrary: () -> Void

    init(model: VMListModel, showLibrary: @escaping () -> Void) {
        self.model = model
        self.showLibrary = showLibrary
    }

    func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: "openVM")
        appItem.submenu = app
        app.addItem(
            withTitle: "About openVM", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide openVM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit openVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Rebuilt each time it opens, from the host's current list.
        let machineItem = NSMenuItem()
        main.addItem(machineItem)
        let machine = NSMenu(title: "Machine")
        machine.delegate = self
        machineItem.submenu = machine

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        windowItem.submenu = window
        let library = window.addItem(
            withTitle: "Library", action: #selector(openLibrary(_:)), keyEquivalent: "0")
        library.target = self
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !model.vms.isEmpty else {
            let none = menu.addItem(withTitle: "No virtual machines", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for vm in model.vms {
            let item = menu.addItem(
                withTitle: "Open \(vm.name)", action: #selector(openWindow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = vm.uuid
        }
    }

    @objc private func openLibrary(_ item: NSMenuItem) { showLibrary() }

    @objc private func openWindow(_ item: NSMenuItem) {
        guard let uuid = item.representedObject as? String, let vm = model.vm(uuid: uuid) else { return }
        WindowRegistry.shared.show(vm, transport: model.transport) { [model] vm in Task { await model.start(vm) } }
    }
}
