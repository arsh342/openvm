// The Virtual Machine menu in the menu bar, the menu under the menu-bar icon, and the order of the menu bar.
import AppKit
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
struct MachineMenusTests {
    private final class Log { var calls: [String] = [] }

    private func make(_ rows: [CBOR], lastUsed: String? = nil) async -> (MachineMenus, FakeTransport, Log, VMListModel) {
        let host = FakeTransport()
        host.rows = rows
        let model = VMListModel(transport: host)
        await model.refresh()
        let log = Log()
        let context = VMCommandContext(
            model: model, openWindow: { log.calls.append("open \($0.name)") },
            showSettings: { log.calls.append("settings \($0.name)") },
            shareFolder: { log.calls.append("share \($0.name)") },
            confirmDelete: { log.calls.append("confirm delete \($0.name)") })
        let actions = MachineMenuActions(
            showLibrary: { log.calls.append("library") }, newVM: { log.calls.append("new") },
            lastUsed: { lastUsed }, use: { log.calls.append("use \($0)") })
        return (MachineMenus(model: model, context: context, actions: actions), host, log, model)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    private func named(_ name: String, _ state: String) -> VmSummary {
        VmSummary(row: FakeTransport.row(name, state: state))!
    }

    // MARK: the current VM (the icon's menu only)

    @Test func theVmLastUsedIsCurrent() {
        let vms = [named("a", "running"), named("b", "stopped")]
        #expect(MachineMenus.current(in: vms, lastUsed: "uuid-b")?.name == "b")
    }

    @Test func withoutOneALiveVmIsPreferred() {
        let vms = [named("a", "stopped"), named("b", "suspended"), named("c", "running")]
        #expect(MachineMenus.current(in: vms, lastUsed: nil)?.name == "b")
        #expect(MachineMenus.current(in: vms, lastUsed: "uuid-deleted")?.name == "b")
    }

    @Test func otherwiseTheFirstAndWithNoVmsNone() {
        #expect(MachineMenus.current(in: [named("a", "stopped"), named("b", "stopped")], lastUsed: nil)?.name == "a")
        #expect(MachineMenus.current(in: [], lastUsed: nil) == nil)
    }

    // MARK: the menu under the icon

    @Test func theStatusMenuListsVmsWithTheCurrentOneTicked() async {
        let (menus, _, _, _) = await make([FakeTransport.row("a", state: "stopped"), FakeTransport.row("b", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        #expect(titles(menu) == [
            "a", "b", "Running · Windows · 4 CPUs · 4 GB memory", "-", "Shut Down", "Restart", "Pause", "-", "Devices",
            "Settings…", "-", "Show Library", "New Virtual Machine…", "-", "About openVM", "Quit openVM",
        ])
        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)
        #expect(!menu.items[2].isEnabled)  // the summary is information, not a command
    }

    @Test func withNoVmsTheStatusMenuSaysSoAndItsCommandsAreOff() async {
        let (menus, _, _, _) = await make([])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        #expect(menu.items[0].title == "No virtual machines")
        #expect(!menu.items[0].isEnabled)
        #expect(titles(menu).contains("Show Library"))
        #expect(menu.items.first { $0.title == "Shut Down" }?.isEnabled == false)
    }

    @Test func updatingTwiceDoesNotRepeatTheVms() async {
        let (menus, _, _, _) = await make([FakeTransport.row("a", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        menus.menuNeedsUpdate(menu)
        #expect(titles(menu).filter { $0 == "a" }.count == 1)
    }

    @Test func choosingAVmMakesItCurrentAndOpensIt() async {
        let (menus, _, log, _) = await make([FakeTransport.row("a", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        // The row is wired to choose its VM; choosing is tested directly (sending the action needs NSApp).
        #expect(menu.items[0].target === menus)
        #expect(menu.items[0].action != nil)
        #expect(menu.items[0].representedObject as? String == "uuid-a")
        menus.choose("uuid-a")
        #expect(log.calls == ["use uuid-a", "open a"])
    }

    @Test func theIconsCommandsFollowTheCurrentVmAndAnswerToTheMenus() async {
        let (menus, _, _, _) = await make([FakeTransport.row("a", state: "suspended")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        let commands = menu.items.filter { VMCommand.from($0) != nil }
        #expect(commands.map(\.title) == ["Shut Down", "Restart", "Resume", "Settings…"])
        #expect(commands.allSatisfy { $0.target === menus })  // no window is in front to answer
        #expect(commands.allSatisfy { $0.keyEquivalent.isEmpty })  // shortcuts belong to the menu bar
        #expect(commands[1].isEnabled == false)  // a paused guest cannot restart
        let devices = menu.items.first { $0.title == "Devices" }!.submenu!
        menus.menuNeedsUpdate(devices)
        #expect(titles(devices) == ["Share Clipboard", "Accept Files from the VM", "-", "Share Folder…", "Eject Installer"])
        #expect(devices.items[0].state == .on)
        #expect(devices.items[0].target === menus)
    }

    @Test func aCommandReachesTheHostForTheCurrentVm() async {
        let (menus, host, _, _) = await make([FakeTransport.row("a", state: "running")])
        await menus.perform(.pause)
        #expect(host.arg("suspend", "id") == .text("uuid-a"))
    }

    // MARK: the menu bar

    /// The menu bar's items have no target, so they act on the window in front, never on a hidden
    /// "current VM". With no such window they are off, under their plain names.
    @Test func theMenuBarsCommandsHaveNoTarget() async {
        let (menus, _, _, _) = await make([FakeTransport.row("a", state: "stopped")])
        let menu = menus.virtualMachineMenu()
        menus.menuNeedsUpdate(menu)
        #expect(titles(menu) == ["Shut Down", "Restart", "Pause", "-", "Devices", "-", "Settings…", "-", "Delete…"])
        let commands = menu.items.filter { VMCommand.from($0) != nil }
        #expect(commands.allSatisfy { $0.target == nil && $0.action == VMCommand.action })
        #expect(menu.autoenablesItems)
    }

    /// A title left by the last window in front must not stay when another kind of window comes forward.
    @Test func theMenuBarGoesBackToPlainNamesBeforeEachUse() async {
        let (menus, _, _, _) = await make([FakeTransport.row("a", state: "stopped")])
        let menu = menus.virtualMachineMenu()
        let power = menu.items[0]
        #expect(VMCommand.validate(power, for: named("a", "stopped")))
        #expect(power.title == "Start")
        menus.menuNeedsUpdate(menu)
        #expect(power.title == "Shut Down")
    }

    @Test func theMenuBarIsInApplesOrder() async {
        let (menus, _, _, model) = await make([])
        let menu = AppMenu(
            model: model, machine: menus, showLibrary: {}, newVM: {}, showSettings: {}, openVM: { _ in }
        ).build()
        #expect(menu.items.map { $0.submenu?.title ?? "" } == AppMenu.order)
        #expect(AppMenu.order == ["openVM", "File", "Edit", "View", "Virtual Machine", "Window", "Help"])
        // Settings is the app's, on Command-comma; a VM's settings are on Option-Command-comma.
        let settings = menu.items[0].submenu!.items.first { $0.title == "Settings…" }
        #expect(settings?.keyEquivalent == ",")
        #expect(settings?.keyEquivalentModifierMask == [.command])
        let edit = menu.items[2].submenu!
        #expect(edit.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All"])
        #expect(edit.items.allSatisfy { $0.target == nil })  // the text field in front answers
    }

    /// No two items in the menu bar share a shortcut.
    @Test func noShortcutIsUsedTwice() async {
        let (menus, _, _, model) = await make([])
        let menu = AppMenu(
            model: model, machine: menus, showLibrary: {}, newVM: {}, showSettings: {}, openVM: { _ in }
        ).build()
        var seen: [String: String] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let key = "\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)"
                    #expect(seen[key] == nil, "\(item.title) and \(seen[key] ?? "") share a shortcut")
                    seen[key] = item.title
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
    }
}
