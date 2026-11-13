// MachineMenus — the Virtual Machine menu in the menu bar, and the menu under the menu-bar icon. Both
// are built from the one list of commands (VMCommand), so they can never disagree.
//
// They differ in which VM they act on. A menu-bar command goes to the window in front through the
// responder chain: a VM's window answers for its VM, the library for the VM selected in it, and with
// neither in front the command is off. The menu under the icon opens with no window of ours in front,
// so it acts on the current VM (the one last used), which it lists and lets a person change.
import AppKit
import OpenVMCore

/// What the menus need from the rest of the app, besides the commands themselves.
struct MachineMenuActions {
    let showLibrary: () -> Void
    let newVM: () -> Void
    let lastUsed: () -> String?
    let use: (String) -> Void
}

@MainActor
final class MachineMenus: NSObject, NSMenuDelegate {
    private let model: VMListModel
    private let context: VMCommandContext
    private let actions: MachineMenuActions
    /// Marks the rows at the top of the icon's menu, which are rebuilt each time it opens.
    private static let dynamicTag = 7001
    private var statusRoot: NSMenu?
    /// The menus under the icon, whose items this object enables itself.
    private var statusMenus: [NSMenu] = []
    private var menuBarMenus: [NSMenu] = []

    init(model: VMListModel, context: VMCommandContext, actions: MachineMenuActions) {
        self.model = model
        self.context = context
        self.actions = actions
    }

    /// The VM the icon's menu acts on: the one last used, else one that is live, else the first.
    nonisolated static func current(in vms: [VmSummary], lastUsed: String?) -> VmSummary? {
        vms.first { $0.uuid == lastUsed }
            ?? vms.first { $0.state == .running || $0.state == .suspended }
            ?? vms.first
    }

    /// "Running · Linux · 4 CPUs · 4 GB memory": the current VM at a glance.
    static func summary(_ vm: VmSummary) -> String {
        VMStatus.of(vm).word + " · " + VMRowLogic.subtitle(for: vm)
    }

    private var current: VmSummary? { Self.current(in: model.vms, lastUsed: actions.lastUsed()) }

    // MARK: the menu bar

    /// Virtual Machine, for the menu bar. Its items have no target: the window in front answers.
    func virtualMachineMenu() -> NSMenu {
        let menu = NSMenu(title: "Virtual Machine")
        menu.delegate = self
        for item in VMCommand.items(VMCommand.menuBar, shortcuts: true, delegate: self) { menu.addItem(item) }
        menuBarMenus = [menu] + menu.items.compactMap(\.submenu)
        return menu
    }

    // MARK: the menu under the icon

    /// The VMs, the current one's state, its commands, then the way back to the app.
    func statusMenu() -> NSMenu {
        let menu = NSMenu(title: "openVM")
        menu.delegate = self
        statusRoot = menu
        for item in VMCommand.items(VMCommand.statusItem, shortcuts: false, delegate: self) {
            menu.addItem(item)
        }
        statusMenus = [menu] + menu.items.compactMap(\.submenu)
        for owned in statusMenus {
            owned.autoenablesItems = false  // each item is set in `menuNeedsUpdate`
            for item in owned.items where VMCommand.from(item) != nil {
                item.target = self
                item.action = #selector(run(_:))
            }
        }
        menu.addItem(.separator())
        addPlain("Show Library", #selector(showLibrary(_:)), to: menu)
        addPlain("New Virtual Machine…", #selector(newVirtualMachine(_:)), to: menu)
        menu.addItem(.separator())
        addPlain("About openVM", #selector(about(_:)), to: menu)
        addPlain("Quit openVM", #selector(quit(_:)), to: menu)
        return menu
    }

    private func addPlain(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: keeping them current

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menuBarMenus.contains(where: { $0 === menu }) {
            // Back to the plain names first. The window in front then says what each is for its VM
            // (validateMenuItem); with no such window the items stay plain, and off.
            for item in menu.items {
                if let command = VMCommand.from(item) { command.apply(command.state(for: nil), to: item) }
            }
            return
        }
        if menu === statusRoot { rebuildVmList(menu) }
        let vm = current
        for item in menu.items {
            guard let command = VMCommand.from(item) else { continue }
            let state = command.state(for: vm)
            command.apply(state, to: item)
            item.isEnabled = state.enabled
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
        let text = chosen.map(Self.summary) ?? "No virtual machines"
        let summary = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        rows.append(summary)
        // A download goes on with every window closed, so it shows here too.
        for row in model.downloading {
            let percent =
                DownloadText.fraction(done: row.bytes, total: row.bytesTotal).map { " \(Int($0 * 100))%" }
                ?? ""
            let line = NSMenuItem(title: "Downloading \(row.name)\(percent)", action: nil, keyEquivalent: "")
            line.isEnabled = false
            rows.append(line)
        }
        rows.append(.separator())
        for (index, row) in rows.enumerated() {
            row.tag = Self.dynamicTag
            menu.insertItem(row, at: index)
        }
    }

    // MARK: acting

    @objc private func run(_ item: NSMenuItem) {
        guard let command = VMCommand.from(item) else { return }
        Task { await perform(command) }
    }

    /// Does a command for the current VM.
    func perform(_ command: VMCommand) async {
        guard let vm = current else { return }
        await command.perform(on: vm, in: context)
    }

    @objc private func chooseVm(_ item: NSMenuItem) {
        if let uuid = item.representedObject as? String { choose(uuid) }
    }

    /// Makes a VM the current one, and brings up its window.
    func choose(_ uuid: String) {
        guard let vm = model.vm(uuid: uuid) else { return }
        actions.use(uuid)
        context.openWindow(vm)
    }

    @objc private func showLibrary(_ item: NSMenuItem) { actions.showLibrary() }
    @objc private func newVirtualMachine(_ item: NSMenuItem) { actions.newVM() }
    @objc private func quit(_ item: NSMenuItem) { NSApp.terminate(nil) }

    @objc private func about(_ item: NSMenuItem) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}
