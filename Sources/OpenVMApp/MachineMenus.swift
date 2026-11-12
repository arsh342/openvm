// MachineMenus — the View, Actions and Devices menus, and the menu under the menu-bar icon. One piece of
// code feeds them all, so the menu bar and the icon can never disagree. They act on the current VM
// (MachineMenuLogic.current), which also works with the app in the background: the icon's menu opens
// without any of our windows being key.
//
// Only commands that work are listed. A menu item for a feature that does not exist misleads.
import AppKit
import OpenVMCore

/// What the menus need from the rest of the app.
struct MachineMenuActions {
    let openWindow: (VmSummary) -> Void
    let showSettings: (VmSummary) -> Void
    let showLibrary: () -> Void
    let newVM: () -> Void
    let toggleFullScreen: (VmSummary) -> Void
    let shareFolder: (VmSummary) -> Void
    /// The display choice changed: fit the guest again.
    let displayChanged: (VmSummary) -> Void
    let isFullScreen: (String) -> Bool
    let lastUsed: () -> String?
    let use: (String) -> Void
}

@MainActor
final class MachineMenus: NSObject, NSMenuDelegate {
    private let model: VMListModel
    private let actions: MachineMenuActions
    private let hold: WindowsDisplayHold
    /// Marks the rows at the top of the icon's menu, which are rebuilt each time it opens.
    private static let dynamicTag = 7001
    private var commands: [ObjectIdentifier: MachineCommand] = [:]
    private var statusRoot: NSMenu?

    init(model: VMListModel, actions: MachineMenuActions, hold: WindowsDisplayHold = WindowsDisplayHold()) {
        self.model = model
        self.actions = actions
        self.hold = hold
    }

    private var current: VmSummary? { MachineMenuLogic.current(in: model.vms, lastUsed: actions.lastUsed()) }

    // MARK: the menus

    func viewMenu() -> NSMenu {
        let menu = make("View")
        let full = add(.fullScreen, to: menu)
        full.keyEquivalent = "f"
        full.keyEquivalentModifierMask = [.command, .control]
        add(.reverseScrolling, to: menu)
        add(.fullSizeDisplay, to: menu)
        return menu
    }

    func actionsMenu(settingsKey: String = "") -> NSMenu {
        let menu = make("Actions")
        add(.power, to: menu)
        add(.restart, to: menu)
        menu.addItem(.separator())
        add(.pause, to: menu)
        menu.addItem(.separator())
        add(.settings, to: menu).keyEquivalent = settingsKey
        return menu
    }

    func devicesMenu() -> NSMenu {
        let menu = make("Devices")
        add(.clipboard, to: menu)
        add(.outbox, to: menu)
        menu.addItem(.separator())
        add(.shareFolder, to: menu)
        add(.ejectInstaller, to: menu)
        return menu
    }

    /// The menu under the menu-bar icon: the VMs, the current one's state, then the same commands.
    func statusMenu() -> NSMenu {
        let menu = make("openVM")
        statusRoot = menu
        for (title, submenu) in [("View", viewMenu()), ("Actions", actionsMenu()), ("Devices", devicesMenu())] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        // Shortcuts belong to the menu bar: the same one twice would make the choice of menu arbitrary.
        clearKeyEquivalents(menu)
        add(.settings, to: menu)
        menu.addItem(.separator())
        addPlain("Show Library", #selector(showLibrary(_:)), to: menu)
        addPlain("New Virtual Machine…", #selector(newVirtualMachine(_:)), to: menu)
        menu.addItem(.separator())
        addPlain("About openVM", #selector(about(_:)), to: menu)
        addPlain("Quit openVM", #selector(quit(_:)), to: menu)
        return menu
    }

    private func clearKeyEquivalents(_ menu: NSMenu) {
        for item in menu.items {
            item.keyEquivalent = ""
            if let submenu = item.submenu { clearKeyEquivalents(submenu) }
        }
    }

    private func make(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false  // each item says for itself, in `apply`
        menu.delegate = self
        return menu
    }

    @discardableResult
    private func add(_ command: MachineCommand, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        commands[ObjectIdentifier(item)] = command
        apply(command, to: item)
        menu.addItem(item)
        return item
    }

    private func addPlain(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: keeping them current

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusRoot { rebuildVmList(menu) }
        for item in menu.items {
            if let command = commands[ObjectIdentifier(item)] { apply(command, to: item) }
        }
    }

    private func apply(_ command: MachineCommand, to item: NSMenuItem) {
        let vm = current
        let state = MachineMenuLogic.item(
            command, for: vm,
            fullScreen: vm.map { actions.isFullScreen($0.uuid) } ?? false,
            fullSize: vm.map { hold.isLifted($0.uuid) } ?? false)
        item.title = state.title
        item.isEnabled = state.enabled
        item.state = state.checked ? .on : .off
        item.image = MachineMenuLogic.symbol(command, for: vm).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: state.title)
        }
    }

    private func rebuildVmList(_ menu: NSMenu) {
        while let first = menu.items.first, first.tag == Self.dynamicTag { menu.removeItem(first) }
        var rows: [NSMenuItem] = []
        let chosen = current
        for vm in model.vms {
            let row = NSMenuItem(title: vm.name, action: #selector(chooseVm(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = vm.uuid
            row.state = vm.uuid == chosen?.uuid ? .on : .off
            rows.append(row)
        }
        let text = chosen.map(MachineMenuLogic.summary) ?? "No virtual machines"
        let summary = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        rows.append(summary)
        rows.append(.separator())
        for (index, row) in rows.enumerated() {
            row.tag = Self.dynamicTag
            menu.insertItem(row, at: index)
        }
    }

    // MARK: acting

    @objc private func run(_ item: NSMenuItem) {
        guard let command = commands[ObjectIdentifier(item)] else { return }
        Task { await perform(command) }
    }

    func perform(_ command: MachineCommand) async {
        guard let vm = current else { return }
        switch command {
        case .power:
            switch VMToolbarLogic.state(for: vm).power {
            case .start:
                actions.openWindow(vm)
                await model.start(vm)
            case .shutDown, .cancel: await model.stop(vm)
            case .disabled: break
            }
        case .restart: await model.restart(vm)
        case .pause:
            switch VMToolbarLogic.state(for: vm).pause {
            case .pause: await model.suspend(vm)
            case .resume: await model.resume(vm)
            case .disabled: break
            }
        case .fullScreen: actions.toggleFullScreen(vm)
        case .reverseScrolling: ScrollFlip.setReversed(!ScrollFlip.isReversed())
        case .fullSizeDisplay:
            guard vm.bootMode == .windows else { break }
            hold.setLifted(!hold.isLifted(vm.uuid), for: vm.uuid)
            actions.displayChanged(vm)
        case .shareFolder: actions.shareFolder(vm)
        case .clipboard: await model.setClipboardSync(vm, !vm.clipboardSync)
        case .outbox: await model.setOutbox(vm, !vm.outbox)
        case .ejectInstaller: await model.ejectInstaller(vm)
        case .settings: actions.showSettings(vm)
        }
    }

    @objc private func chooseVm(_ item: NSMenuItem) {
        if let uuid = item.representedObject as? String { choose(uuid) }
    }

    /// Makes a VM the current one, and brings up its window.
    func choose(_ uuid: String) {
        guard let vm = model.vm(uuid: uuid) else { return }
        actions.use(uuid)
        actions.openWindow(vm)
    }

    @objc private func showLibrary(_ item: NSMenuItem) { actions.showLibrary() }
    @objc private func newVirtualMachine(_ item: NSMenuItem) { actions.newVM() }
    @objc private func quit(_ item: NSMenuItem) { NSApp.terminate(nil) }

    @objc private func about(_ item: NSMenuItem) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
