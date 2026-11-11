// What the menus offer for the current VM: each command's title, whether it is live, and whether it
// is ticked. Plain functions of the VM's summary.
import AppKit
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct MachineMenuLogicTests {
    private func vm(_ state: String, activity: String? = nil, clipboardSync: Bool? = nil, outbox: Bool? = nil) -> VmSummary {
        VmSummary(row: FakeTransport.row("w", state: state, activity: activity, clipboardSync: clipboardSync, outbox: outbox))!
    }

    @Test func powerFollowsTheState() {
        #expect(MachineMenuLogic.item(.power, for: vm("stopped")) == .init(title: "Start", enabled: true))
        #expect(MachineMenuLogic.item(.power, for: vm("running")) == .init(title: "Shut Down", enabled: true))
        #expect(MachineMenuLogic.item(.power, for: vm("stopped", activity: "start"))
            == .init(title: "Cancel Start", enabled: true))
    }

    @Test func pauseBecomesResumeWhenPaused() {
        #expect(MachineMenuLogic.item(.pause, for: vm("running")) == .init(title: "Pause", enabled: true))
        #expect(MachineMenuLogic.item(.pause, for: vm("suspended")) == .init(title: "Resume", enabled: true))
        #expect(MachineMenuLogic.item(.pause, for: vm("stopped")) == .init(title: "Pause", enabled: false))
    }

    @Test func restartNeedsARunningGuestTheHostIsNotBusyWith() {
        #expect(MachineMenuLogic.item(.restart, for: vm("running")).enabled)
        #expect(!MachineMenuLogic.item(.restart, for: vm("stopped")).enabled)
        #expect(!MachineMenuLogic.item(.restart, for: vm("suspended")).enabled)
        #expect(!MachineMenuLogic.item(.restart, for: vm("running", activity: "stop")).enabled)
    }

    @Test func nothingIsLiveWhileTheHostIsBusyWithTheVm() {
        let busy = vm("running", activity: "stop")
        #expect(MachineMenuLogic.item(.power, for: busy).enabled == false)
        #expect(MachineMenuLogic.item(.pause, for: busy).enabled == false)
    }

    @Test func fullScreenNeedsAGuestToShowAndSaysWhichWay() {
        #expect(MachineMenuLogic.item(.fullScreen, for: vm("running")).enabled)
        #expect(!MachineMenuLogic.item(.fullScreen, for: vm("stopped")).enabled)
        #expect(MachineMenuLogic.item(.fullScreen, for: vm("running")).title == "Enter Full Screen")
        #expect(MachineMenuLogic.item(.fullScreen, for: vm("running"), fullScreen: true).title == "Exit Full Screen")
    }

    @Test func switchesAreTickedWhenOn() {
        #expect(MachineMenuLogic.item(.clipboard, for: vm("running")).checked)
        #expect(!MachineMenuLogic.item(.clipboard, for: vm("running", clipboardSync: false)).checked)
        #expect(MachineMenuLogic.item(.outbox, for: vm("running")).checked)
        #expect(!MachineMenuLogic.item(.outbox, for: vm("running", outbox: false)).checked)
    }

    @Test func settingsAndSharingAreAlwaysThereForAVm() {
        for state in ["stopped", "running", "suspended"] {
            #expect(MachineMenuLogic.item(.settings, for: vm(state)).enabled)
            #expect(MachineMenuLogic.item(.shareFolder, for: vm(state)).enabled)
        }
    }

    @Test func withNoVmEverythingIsOff() {
        for command in MachineCommand.allCases {
            #expect(!MachineMenuLogic.item(command, for: nil).enabled, "\(command)")
        }
    }

    private func named(_ name: String, _ state: String) -> VmSummary {
        VmSummary(row: FakeTransport.row(name, state: state))!
    }

    @Test func theVmLastUsedIsCurrent() {
        let vms = [named("a", "running"), named("b", "stopped")]
        #expect(MachineMenuLogic.current(in: vms, lastUsed: "uuid-b")?.name == "b")
    }

    @Test func withoutOneALiveVmIsPreferred() {
        let vms = [named("a", "stopped"), named("b", "suspended"), named("c", "running")]
        #expect(MachineMenuLogic.current(in: vms, lastUsed: nil)?.name == "b")
        #expect(MachineMenuLogic.current(in: vms, lastUsed: "uuid-deleted")?.name == "b")
    }

    @Test func otherwiseTheFirstAndWithNoVmsNone() {
        #expect(MachineMenuLogic.current(in: [named("a", "stopped"), named("b", "stopped")], lastUsed: nil)?.name == "a")
        #expect(MachineMenuLogic.current(in: [], lastUsed: nil) == nil)
    }
}

@MainActor
struct MachineMenusTests {
    private final class Log { var calls: [String] = [] }

    private func make(_ rows: [CBOR], lastUsed: String? = nil) async -> (MachineMenus, FakeTransport, Log) {
        let host = FakeTransport()
        host.rows = rows
        let model = VMListModel(transport: host)
        await model.refresh()
        let log = Log()
        let actions = MachineMenuActions(
            openWindow: { log.calls.append("open \($0.name)") },
            showSettings: { log.calls.append("settings \($0.name)") },
            showLibrary: { log.calls.append("library") },
            newVM: { log.calls.append("new") },
            toggleFullScreen: { log.calls.append("fullscreen \($0.name)") },
            shareFolder: { log.calls.append("share \($0.name)") },
            isFullScreen: { _ in false },
            lastUsed: { lastUsed },
            use: { log.calls.append("use \($0)") })
        return (MachineMenus(model: model, actions: actions), host, log)
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "-" : $0.title } }

    @Test func theStatusMenuListsVmsWithTheCurrentOneTicked() async {
        let (menus, _, _) = await make([FakeTransport.row("a", state: "stopped"), FakeTransport.row("b", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        #expect(titles(menu) == [
            "a", "b", "Running · Windows · 4 CPUs · 4 GB memory", "-", "View", "Actions", "Devices", "Settings…", "-",
            "Show Library", "New Virtual Machine…", "-", "About openVM", "Quit openVM",
        ])
        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)
        #expect(!menu.items[2].isEnabled)  // the summary is information, not a command
    }

    @Test func withNoVmsTheStatusMenuSaysSo() async {
        let (menus, _, _) = await make([])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        #expect(menu.items[0].title == "No virtual machines")
        #expect(!menu.items[0].isEnabled)
        #expect(titles(menu).contains("Show Library"))
    }

    @Test func updatingTwiceDoesNotRepeatTheVms() async {
        let (menus, _, _) = await make([FakeTransport.row("a", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        menus.menuNeedsUpdate(menu)
        #expect(titles(menu).filter { $0 == "a" }.count == 1)
    }

    @Test func choosingAVmMakesItCurrentAndOpensIt() async {
        let (menus, _, log) = await make([FakeTransport.row("a", state: "running")])
        let menu = menus.statusMenu()
        menus.menuNeedsUpdate(menu)
        // The row is wired to choose its VM; choosing is tested directly (sending the action needs NSApp).
        #expect(menu.items[0].target === menus)
        #expect(menu.items[0].action != nil)
        #expect(menu.items[0].representedObject as? String == "uuid-a")
        menus.choose("uuid-a")
        #expect(log.calls == ["use uuid-a", "open a"])
    }

    @Test func theActionsMenuFollowsTheCurrentVm() async {
        let (menus, _, _) = await make([FakeTransport.row("a", state: "suspended")])
        let actions = menus.actionsMenu()
        menus.menuNeedsUpdate(actions)
        #expect(titles(actions) == ["Shut Down", "Restart", "-", "Resume", "-", "Settings…"])
        #expect(!actions.items[1].isEnabled)  // a paused guest cannot restart
    }

    @Test func aCommandReachesTheHostForTheCurrentVm() async {
        let (menus, host, _) = await make([FakeTransport.row("a", state: "running")])
        await menus.perform(.pause)
        #expect(host.arg("suspend", "id") == .text("uuid-a"))
    }

    @Test func startingAlsoOpensTheWindow() async {
        let (menus, host, log) = await make([FakeTransport.row("a", state: "stopped")])
        await menus.perform(.power)
        #expect(host.calls.contains("start"))
        #expect(log.calls == ["open a"])
    }

    @Test func theSwitchesReachTheHost() async {
        let (menus, host, _) = await make([FakeTransport.row("a", state: "running")])
        await menus.perform(.clipboard)
        #expect(host.arg("set", "clipboard-sync") == .bool(false))
        await menus.perform(.outbox)
        #expect(host.arg("set", "outbox") == .bool(false))
    }
}

/// An Alpine guest left over from an earlier openVM cannot run, so nothing that needs a guest is offered.
struct RetiredAlpineMenuTests {
    @Test func nothingThatNeedsTheAgentIsOffered() {
        let old = VmSummary(row: FakeTransport.row("srv1", state: "stopped", bootMode: "linux"))!
        #expect(old.bootMode == .alpine)
        for command in [MachineCommand.outbox, .shareFolder, .clipboard] {
            #expect(!MachineMenuLogic.item(command, for: old).enabled, "\(command)")
        }
        #expect(MachineMenuLogic.item(.settings, for: old).enabled)
    }
}

struct IsoGuestMenuTests {
    private func vm(_ state: String, attached: Bool = false) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text("w")), ("state", .text(state)), ("uuid", .text("u")), ("bootMode", .text("linux-iso")),
        ]
        if attached { fields.append(("installerAttached", .bool(true))) }
        return VmSummary(row: .map(fields))!
    }

    @Test func whatNeedsTheAgentIsOff() {
        for command in [MachineCommand.outbox, .shareFolder] {
            #expect(!MachineMenuLogic.item(command, for: vm("running")).enabled, "\(command)")
        }
    }

    /// The clipboard can be shared through the framework's own Spice agent instead. It is off unless chosen.
    @Test func clipboardIsOfferedButOffUntilChosen() {
        let item = MachineMenuLogic.item(.clipboard, for: vm("running"))
        #expect(item.enabled)
        #expect(!item.checked)
        let on = VmSummary(row: FakeTransport.row("w", state: "running", bootMode: "linux-iso", clipboardSync: true))!
        #expect(MachineMenuLogic.item(.clipboard, for: on).checked)
    }

    @Test func powerStillWorks() {
        #expect(MachineMenuLogic.item(.power, for: vm("stopped")).title == "Start")
        #expect(MachineMenuLogic.item(.pause, for: vm("running")).enabled)
        #expect(MachineMenuLogic.item(.restart, for: vm("running")).enabled)
    }

    @Test func theInstallerEjectsFromAStoppedVmOnly() {
        #expect(MachineMenuLogic.item(.ejectInstaller, for: vm("stopped", attached: true)).enabled)
        #expect(!MachineMenuLogic.item(.ejectInstaller, for: vm("running", attached: true)).enabled)
        #expect(!MachineMenuLogic.item(.ejectInstaller, for: vm("stopped")).enabled)
    }
}
