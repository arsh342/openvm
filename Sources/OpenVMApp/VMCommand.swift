// VMCommand — every command that acts on a VM, defined once: what it is called, its symbol, its
// shortcut, when it is live and what it does. The menu bar, the menu under the menu-bar icon, the
// library and the VM window all render from this list, so a name or a rule changes in one place.
//
// Only commands that work are listed. A command for a feature that does not exist misleads.
import AppKit
import OpenVMCore

enum VMCommand: String, CaseIterable {
    case open, power, restart, pause
    case shareClipboard, acceptFiles, shareFolder, ejectInstaller
    case settings, delete
}

/// How a command shows for one VM right now.
struct VMCommandState: Equatable {
    var title: String
    var symbol: String
    var enabled: Bool
    /// A switch that is on (Share Clipboard, Accept Files from the VM).
    var checked = false
}

/// What the power command does now.
enum VMPower: Equatable {
    case start, shutDown, cancelStart, unavailable

    static func of(_ vm: VmSummary) -> VMPower {
        // A boot in progress can be cancelled; nothing else can be done to a VM the host is busy with.
        if let activity = vm.activity { return activity == "start" ? .cancelStart : .unavailable }
        switch vm.state {
        case .stopped: return .start
        case .running, .suspended: return .shutDown
        case .starting, .stopping: return .unavailable
        }
    }
}

/// What the pause command does now.
enum VMPause: Equatable {
    case pause, resume, unavailable

    static func of(_ vm: VmSummary) -> VMPause {
        guard vm.activity == nil else { return .unavailable }
        switch vm.state {
        case .running: return .pause
        case .suspended: return .resume
        case .stopped, .starting, .stopping: return .unavailable
        }
    }
}

extension VMCommand {
    /// `vm` is nil when there is no VM to act on: the command keeps its name and is off.
    func state(for vm: VmSummary?) -> VMCommandState {
        guard let vm else { return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: false) }
        let idle = vm.activity == nil
        switch self {
        case .open: return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: true)
        case .power:
            switch VMPower.of(vm) {
            case .start: return VMCommandState(title: "Start", symbol: "play.fill", enabled: true)
            case .shutDown: return VMCommandState(title: "Shut Down", symbol: "power", enabled: true)
            case .cancelStart: return VMCommandState(title: "Cancel Start", symbol: "xmark.circle", enabled: true)
            case .unavailable: return VMCommandState(title: "Shut Down", symbol: "power", enabled: false)
            }
        case .restart:
            return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: vm.state == .running && idle)
        case .pause:
            switch VMPause.of(vm) {
            case .pause: return VMCommandState(title: "Pause", symbol: "pause.fill", enabled: true)
            case .resume: return VMCommandState(title: "Resume", symbol: "play.fill", enabled: true)
            case .unavailable: return VMCommandState(title: "Pause", symbol: "pause.fill", enabled: false)
            }
        // A guest from its own ISO can share the clipboard through the framework's Spice agent (next start).
        case .shareClipboard:
            let offered = vm.bootMode.hasAgent || vm.bootMode == .linuxISO
            return VMCommandState(
                title: defaultTitle, symbol: defaultSymbol, enabled: offered, checked: offered && vm.clipboardSync)
        // These work through the guest's openVM tools, so a guest without them has nothing to offer.
        case .acceptFiles:
            return VMCommandState(
                title: defaultTitle, symbol: defaultSymbol, enabled: vm.bootMode.hasAgent,
                checked: vm.bootMode.hasAgent && vm.outbox)
        case .shareFolder:
            return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: vm.bootMode.hasAgent)
        case .ejectInstaller:
            return VMCommandState(
                title: defaultTitle, symbol: defaultSymbol,
                enabled: vm.installerAttached && vm.state == .stopped && idle)
        case .settings: return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: true)
        // A running or paused VM cannot be deleted, nor one the host is busy with.
        case .delete:
            return VMCommandState(title: defaultTitle, symbol: defaultSymbol, enabled: vm.state == .stopped && idle)
        }
    }

    private var defaultTitle: String {
        switch self {
        case .open: return "Open"
        case .power: return "Shut Down"
        case .restart: return "Restart"
        case .pause: return "Pause"
        case .shareClipboard: return "Share Clipboard"
        case .acceptFiles: return "Accept Files from the VM"
        case .shareFolder: return "Share Folder…"
        case .ejectInstaller: return "Eject Installer"
        case .settings: return "Settings…"
        case .delete: return "Delete…"
        }
    }

    private var defaultSymbol: String {
        switch self {
        case .open: return "macwindow"
        case .power: return "power"
        case .restart: return "arrow.clockwise"
        case .pause: return "pause.fill"
        case .shareClipboard: return "doc.on.clipboard"
        case .acceptFiles: return "tray.and.arrow.down"
        case .shareFolder: return "folder.badge.plus"
        case .ejectInstaller: return "eject"
        case .settings: return "gearshape"
        case .delete: return "trash"
        }
    }

    /// The menu-bar shortcut. Few on purpose: while a guest has the keyboard, key combinations are the
    /// guest's (GuestKeys), so a shortcut here works from the library and a stopped VM's window.
    var shortcut: (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch self {
        case .settings: return (",", [.command, .option])
        case .delete: return ("\u{8}", [.command])
        default: return nil
        }
    }

    // MARK: where the commands are listed

    /// One group of a menu: commands, or a submenu of groups.
    enum MenuEntry: Equatable {
        case command(VMCommand)
        case separator
        case submenu(String, [MenuEntry])
    }

    static let devices: [MenuEntry] = [
        .command(.shareClipboard), .command(.acceptFiles), .separator, .command(.shareFolder),
        .command(.ejectInstaller),
    ]

    /// The Virtual Machine menu in the menu bar.
    static let menuBar: [MenuEntry] = [
        .command(.power), .command(.restart), .command(.pause), .separator, .submenu("Devices", devices),
        .separator, .command(.settings), .separator, .command(.delete),
    ]

    /// The commands under the menu-bar icon. Delete is left to the library: this menu opens with no
    /// window in front, which is no place to confirm losing a disk.
    static let statusItem: [MenuEntry] = [
        .command(.power), .command(.restart), .command(.pause), .separator, .submenu("Devices", devices),
        .command(.settings),
    ]

    /// The one thing most wanted from a VM: start it, resume it, or open its window.
    static func primary(for vm: VmSummary) -> VMCommand {
        if VMPower.of(vm) == .start { return .power }
        if VMPause.of(vm) == .resume { return .pause }
        return .open
    }
}

// MARK: doing them

/// What a command needs from the rest of the app.
@MainActor
struct VMCommandContext {
    let model: VMListModel
    let openWindow: (VmSummary) -> Void
    let showSettings: (VmSummary) -> Void
    /// Asks for a folder, in the VM's window, and shares it.
    let shareFolder: (VmSummary) -> Void
    /// Asks before a VM and its disk are deleted.
    let confirmDelete: (VmSummary) -> Void
}

extension VMCommand {
    /// Does the command for a VM. A command that is off for the VM does nothing.
    @MainActor
    func perform(on vm: VmSummary, in context: VMCommandContext) async {
        guard state(for: vm).enabled else { return }
        let model = context.model
        switch self {
        case .open: context.openWindow(vm)
        case .power:
            switch VMPower.of(vm) {
            case .start:
                context.openWindow(vm)  // so the start can be watched
                await model.start(vm)
            // Shutting down asks the guest to stop. Cancel stops a boot.
            case .shutDown, .cancelStart: await model.stop(vm)
            case .unavailable: break
            }
        case .restart: await model.restart(vm)
        case .pause:
            switch VMPause.of(vm) {
            case .pause: await model.suspend(vm)
            case .resume: await model.resume(vm)
            case .unavailable: break
            }
        case .shareClipboard: await model.setClipboardSync(vm, !vm.clipboardSync)
        case .acceptFiles: await model.setOutbox(vm, !vm.outbox)
        case .shareFolder: context.shareFolder(vm)
        case .ejectInstaller: await model.ejectInstaller(vm)
        case .settings: context.showSettings(vm)
        case .delete: context.confirmDelete(vm)
        }
    }
}

// MARK: menus and the responder chain

/// A window that can say which VM a menu-bar command is for: a VM's window answers with its VM, the
/// library with the VM selected in it. AppKit finds it through the responder chain, so a command
/// always acts on the window in front, and with neither in front it is off.
@objc protocol VMCommandResponder {
    func performVMCommand(_ sender: Any?)
}

extension VMCommand {
    static let action = #selector(VMCommandResponder.performVMCommand(_:))

    /// A menu item for this command, with no target: the responder chain supplies one.
    func menuItem(shortcuts: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: Self.action, keyEquivalent: "")
        item.representedObject = rawValue
        if shortcuts, let shortcut {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        apply(state(for: nil), to: item)
        return item
    }

    /// The command a menu item or toolbar item stands for.
    static func from(_ sender: Any?) -> VMCommand? {
        if let item = sender as? NSMenuItem { return (item.representedObject as? String).flatMap(VMCommand.init) }
        if let item = sender as? NSToolbarItem { return VMCommand(rawValue: item.itemIdentifier.rawValue) }
        return nil
    }

    /// Shows a state on a menu item. The caller decides whether the item is enabled.
    func apply(_ state: VMCommandState, to item: NSMenuItem) {
        item.title = state.title
        item.state = state.checked ? .on : .off
        item.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
    }

    /// For a window's `validateMenuItem`: shows the command as it is for `vm`, and says whether it is live.
    static func validate(_ item: NSMenuItem, for vm: VmSummary?) -> Bool {
        guard let command = from(item) else { return false }
        let state = command.state(for: vm)
        command.apply(state, to: item)
        return state.enabled
    }

    /// Builds the items for a list of entries. `shortcuts` is off for every menu but the menu bar's:
    /// the same shortcut twice would make the choice of menu arbitrary.
    static func items(_ entries: [MenuEntry], shortcuts: Bool, delegate: NSMenuDelegate? = nil) -> [NSMenuItem] {
        entries.map { entry in
            switch entry {
            case .command(let command): return command.menuItem(shortcuts: shortcuts)
            case .separator: return .separator()
            case .submenu(let title, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let menu = NSMenu(title: title)
                menu.delegate = delegate
                for child in items(children, shortcuts: shortcuts, delegate: delegate) { menu.addItem(child) }
                item.submenu = menu
                return item
            }
        }
    }
}

// MARK: status

/// A VM's status in a word and a symbol, never by colour alone. One vocabulary, used everywhere.
struct VMStatus: Equatable {
    enum Tone: Equatable { case running, idle, busy }

    let word: String
    let symbol: String
    let tone: Tone
    /// What a person should know about this state, when there is something.
    var note: String?

    static func of(_ vm: VmSummary) -> VMStatus {
        if vm.installing { return VMStatus(word: "Installing…", symbol: "arrow.down.circle", tone: .busy) }
        if let activity = vm.activity {
            return VMStatus(word: activityWord(activity), symbol: "clock", tone: .busy)
        }
        switch vm.state {
        case .stopped: return VMStatus(word: "Stopped", symbol: "stop.circle", tone: .idle)
        case .running: return VMStatus(word: "Running", symbol: "play.circle.fill", tone: .running)
        case .suspended:
            return VMStatus(
                word: "Paused", symbol: "pause.circle.fill", tone: .idle, note: "Not saved if openVM quits")
        case .starting: return VMStatus(word: "Starting…", symbol: "clock", tone: .busy)
        case .stopping: return VMStatus(word: "Shutting Down…", symbol: "clock", tone: .busy)
        }
    }

    static func activityWord(_ activity: String) -> String {
        switch activity {
        case "start": return "Starting…"
        case "stop": return "Shutting Down…"
        case "suspend": return "Pausing…"
        case "resume": return "Resuming…"
        case "delete": return "Deleting…"
        default: return "Working…"
        }
    }
}

extension VMCommand {
    /// A VM's context menu in the library's table.
    static let pageRows: [VMCommand] = [.open, .power, .restart, .pause, .settings, .delete]
}
