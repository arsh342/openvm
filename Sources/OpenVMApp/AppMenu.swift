// AppMenu — the menu bar, in the order Apple gives every Mac app: openVM, File, Edit, View, Virtual
// Machine, Window, Help. Virtual Machine comes from the one list of VM commands (MachineMenus).
//
// The standard items (Edit, View, Window) have no target: the window in front answers, as in any app.
// While a guest's screen has the keyboard, key combinations go to the guest first (GuestKeys), so
// Command-C in a VM window is the guest's, and in a text field of ours it is Copy.
import AppKit
import OpenVMCore

/// Where the Help menu's items lead.
enum HelpLinks {
    static let readme = URL(string: "https://github.com/arsh342/openvm#readme")!
    static let troubleshooting = URL(string: "https://github.com/arsh342/openvm#before-you-rely-on-it")!
    static let linuxGuests = URL(string: "https://github.com/arsh342/openvm#create-a-linux-guest")!
    static let issues = URL(string: "https://github.com/arsh342/openvm/issues")!
}

@MainActor
final class AppMenu: NSObject, NSMenuDelegate {
    private let model: VMListModel
    private let machine: MachineMenus
    private let showLibrary: () -> Void
    private let newVM: () -> Void
    private let showSettings: () -> Void
    private let openInstaller: () -> Void
    private let openVM: (VmSummary) -> Void

    init(
        model: VMListModel, machine: MachineMenus, showLibrary: @escaping () -> Void,
        newVM: @escaping () -> Void,
        openInstaller: @escaping () -> Void = {}, showSettings: @escaping () -> Void,
        openVM: @escaping (VmSummary) -> Void
    ) {
        self.model = model
        self.machine = machine
        self.showLibrary = showLibrary
        self.newVM = newVM
        self.showSettings = showSettings
        self.openInstaller = openInstaller
        self.openVM = openVM
    }

    /// The titles of the top-level menus, in order.
    static let order = ["openVM", "File", "Edit", "View", "Virtual Machine", "Window", "Help"]

    func build() -> NSMenu {
        let main = NSMenu()
        for menu in [
            appMenu(), fileMenu(), editMenu(), viewMenu(), machine.virtualMachineMenu(), windowMenu(),
            helpMenu(),
        ] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    private func own(_ title: String, _ action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "openVM")
        menu.addItem(
            withTitle: "About openVM", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        _ = own("Settings…", #selector(openSettings(_:)), key: ",", to: menu)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApplication.shared.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide openVM", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit openVM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        _ = own("New Virtual Machine…", #selector(newVirtualMachine(_:)), key: "n", to: menu)
        _ = own("Open Installer File…", #selector(openInstallerFile(_:)), key: "o", to: menu)
        // The list of VMs is rebuilt each time it opens, from the host's current list.
        let openItem = menu.addItem(withTitle: "Open Virtual Machine", action: nil, keyEquivalent: "")
        let openMenu = NSMenu(title: "Open Virtual Machine")
        openMenu.delegate = self
        openItem.submenu = openMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // AppKit names these two itself (Show or Hide, Enter or Exit) for the window in front.
        let sidebar = menu.addItem(
            withTitle: "Show Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
            keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.command, .control]
        let toolbar = menu.addItem(
            withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
        toolbar.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        let full = menu.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        _ = own("Library", #selector(openLibrary(_:)), key: "0", to: menu)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        NSApplication.shared.windowsMenu = menu  // AppKit lists the open windows below
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: "Help")
        for (title, url) in [
            ("openVM Help", HelpLinks.readme),
            ("Linux Guests: Sound, Scrolling and Display", HelpLinks.linuxGuests),
            ("Known Limits", HelpLinks.troubleshooting),
        ] {
            own(title, #selector(openLink(_:)), to: menu).representedObject = url
        }
        menu.addItem(.separator())
        own("Report an Issue…", #selector(openLink(_:)), to: menu).representedObject = HelpLinks.issues
        NSApplication.shared.helpMenu = menu  // gives the system's menu search
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !model.vms.isEmpty else {
            let none = menu.addItem(withTitle: "No Virtual Machines", action: nil, keyEquivalent: "")
            none.isEnabled = false
            return
        }
        for vm in model.vms {
            own(vm.name, #selector(openWindow(_:)), to: menu).representedObject = vm.uuid
        }
    }

    @objc private func openLibrary(_ item: NSMenuItem) { showLibrary() }
    @objc private func newVirtualMachine(_ item: NSMenuItem) { newVM() }
    @objc private func openSettings(_ item: NSMenuItem) { showSettings() }
    @objc private func openInstallerFile(_ item: NSMenuItem) { openInstaller() }

    @objc private func openLink(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openWindow(_ item: NSMenuItem) {
        guard let uuid = item.representedObject as? String, let vm = model.vm(uuid: uuid) else { return }
        openVM(vm)
    }
}
