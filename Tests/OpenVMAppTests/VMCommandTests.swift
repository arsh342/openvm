// The one list of VM commands: what each is called and whether it is live, for every state the host can
// report, and that every place that lists commands uses the same names.
import AppKit
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct VMCommandTests {
    private func vm(
        _ state: String, activity: String? = nil, bootMode: String = "windows", clipboardSync: Bool? = nil,
        outbox: Bool? = nil
    ) -> VmSummary {
        VmSummary(
            row: FakeTransport.row(
                "w", state: state, activity: activity, bootMode: bootMode, clipboardSync: clipboardSync, outbox: outbox))!
    }

    @Test func powerFollowsTheState() {
        #expect(VMCommand.power.state(for: vm("stopped")).title == "Start")
        #expect(VMCommand.power.state(for: vm("running")).title == "Shut Down")
        #expect(VMCommand.power.state(for: vm("suspended")).title == "Shut Down")
        // A boot in progress can be cancelled, and nothing else can be done to it.
        let booting = VMCommand.power.state(for: vm("stopped", activity: "start"))
        #expect(booting.title == "Cancel Start")
        #expect(booting.enabled)
        #expect(!VMCommand.pause.state(for: vm("stopped", activity: "start")).enabled)
    }

    @Test func pauseBecomesResumeWhenPaused() {
        #expect(VMCommand.pause.state(for: vm("running")) == .init(title: "Pause", symbol: "pause.fill", enabled: true))
        #expect(VMCommand.pause.state(for: vm("suspended")) == .init(title: "Resume", symbol: "play.fill", enabled: true))
        #expect(VMCommand.pause.state(for: vm("stopped")) == .init(title: "Pause", symbol: "pause.fill", enabled: false))
    }

    @Test func restartNeedsARunningGuestTheHostIsNotBusyWith() {
        #expect(VMCommand.restart.state(for: vm("running")).enabled)
        #expect(!VMCommand.restart.state(for: vm("stopped")).enabled)
        #expect(!VMCommand.restart.state(for: vm("suspended")).enabled)
        #expect(!VMCommand.restart.state(for: vm("running", activity: "stop")).enabled)
    }

    @Test func anyActivityButABootLocksPowerAndPause() {
        for activity in ["stop", "suspend", "resume", "delete"] {
            let busy = vm("running", activity: activity)
            #expect(!VMCommand.power.state(for: busy).enabled, "\(activity)")
            #expect(!VMCommand.pause.state(for: busy).enabled, "\(activity)")
        }
    }

    @Test func switchesAreTickedWhenOn() {
        #expect(VMCommand.shareClipboard.state(for: vm("running")).checked)
        #expect(!VMCommand.shareClipboard.state(for: vm("running", clipboardSync: false)).checked)
        #expect(VMCommand.acceptFiles.state(for: vm("running")).checked)
        #expect(!VMCommand.acceptFiles.state(for: vm("running", outbox: false)).checked)
    }

    @Test func settingsAndSharingAreAlwaysThereForAVm() {
        for state in ["stopped", "running", "suspended"] {
            #expect(VMCommand.settings.state(for: vm(state)).enabled)
            #expect(VMCommand.shareFolder.state(for: vm(state)).enabled)
            #expect(VMCommand.open.state(for: vm(state)).enabled)
        }
    }

    /// A running or paused VM holds a live guest: only a stopped one the host is not busy with can go.
    @Test func onlyAStoppedIdleVmCanBeDeleted() {
        #expect(VMCommand.delete.state(for: vm("stopped")).enabled)
        #expect(!VMCommand.delete.state(for: vm("running")).enabled)
        #expect(!VMCommand.delete.state(for: vm("suspended")).enabled)
        #expect(!VMCommand.delete.state(for: vm("stopped", activity: "start")).enabled)
    }

    @Test func withNoVmEveryCommandIsOffAndKeepsAName() {
        for command in VMCommand.allCases {
            let state = command.state(for: nil)
            #expect(!state.enabled, "\(command)")
            #expect(!state.title.isEmpty, "\(command)")
            #expect(NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) != nil, "\(command) \(state.symbol)")
        }
    }

    /// Every symbol a command can show exists on this system.
    @Test func everySymbolExists() {
        let vms = [vm("stopped"), vm("running"), vm("suspended"), vm("stopped", activity: "start")]
        for command in VMCommand.allCases {
            for vm in vms {
                let symbol = command.state(for: vm).symbol
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
            }
        }
    }

    // MARK: guests without openVM's tools

    @Test func aGuestFromItsOwnIsoOffersNothingThatNeedsTheTools() {
        let iso = vm("running", bootMode: "linux-iso")
        #expect(!VMCommand.acceptFiles.state(for: iso).enabled)
        #expect(!VMCommand.shareFolder.state(for: iso).enabled)
        // The clipboard can go through the framework's own Spice agent instead. It is off unless chosen.
        let clipboard = VMCommand.shareClipboard.state(for: iso)
        #expect(clipboard.enabled)
        #expect(!clipboard.checked)
        #expect(VMCommand.shareClipboard.state(for: vm("running", bootMode: "linux-iso", clipboardSync: true)).checked)
        #expect(VMCommand.power.state(for: vm("stopped", bootMode: "linux-iso")).title == "Start")
        #expect(VMCommand.pause.state(for: iso).enabled)
        #expect(VMCommand.restart.state(for: iso).enabled)
    }

    /// An Alpine guest left over from an earlier openVM cannot run, so nothing that needs a guest is offered.
    @Test func aRetiredAlpineGuestOffersNothingThatNeedsAGuest() {
        let old = vm("stopped", bootMode: "linux")
        #expect(old.bootMode == .alpine)
        for command in [VMCommand.acceptFiles, .shareFolder, .shareClipboard] {
            #expect(!command.state(for: old).enabled, "\(command)")
        }
        #expect(VMCommand.settings.state(for: old).enabled)
    }

    @Test func theInstallerEjectsFromAStoppedVmOnly() {
        func iso(_ state: String, attached: Bool) -> VmSummary {
            var fields: [(key: String, value: CBOR)] = [
                ("name", .text("w")), ("state", .text(state)), ("uuid", .text("u")), ("bootMode", .text("linux-iso")),
            ]
            if attached { fields.append(("installerAttached", .bool(true))) }
            return VmSummary(row: .map(fields))!
        }
        #expect(VMCommand.ejectInstaller.state(for: iso("stopped", attached: true)).enabled)
        #expect(!VMCommand.ejectInstaller.state(for: iso("running", attached: true)).enabled)
        #expect(!VMCommand.ejectInstaller.state(for: iso("stopped", attached: false)).enabled)
    }

    // MARK: one name everywhere

    private func commands(_ entries: [VMCommand.MenuEntry]) -> [VMCommand] {
        entries.flatMap { entry -> [VMCommand] in
            switch entry {
            case .command(let command): return [command]
            case .separator: return []
            case .submenu(_, let children): return commands(children)
            }
        }
    }

    /// The menu bar lists every command but Open (File ▸ Open Virtual Machine does that), once each.
    @Test func theMenuBarListsEveryCommandOnce() {
        let listed = commands(VMCommand.menuBar)
        #expect(Set(listed) == Set(VMCommand.allCases).subtracting([.open]))
        #expect(listed.count == Set(listed).count)
    }

    @Test func theIconsMenuNeverDeletes() {
        #expect(!commands(VMCommand.statusItem).contains(.delete))
    }

    /// A menu item carries its command, so whoever answers it knows which one was chosen, and takes
    /// its title from the registry.
    @Test @MainActor func aMenuItemShowsTheRegistrysTitleForTheVm() {
        let item = VMCommand.power.menuItem(shortcuts: true)
        #expect(item.action == VMCommand.action)
        #expect(item.target == nil)  // the window in front answers
        #expect(VMCommand.from(item) == .power)
        #expect(VMCommand.validate(item, for: vm("stopped")))
        #expect(item.title == "Start")
        #expect(VMCommand.validate(item, for: vm("running")))
        #expect(item.title == "Shut Down")
        #expect(!VMCommand.validate(item, for: nil))
        #expect(!VMCommand.validate(item, for: vm("running", activity: "stop")))
    }

    @Test @MainActor func onlyTheMenuBarCarriesShortcuts() {
        #expect(VMCommand.settings.menuItem(shortcuts: true).keyEquivalent == ",")
        #expect(VMCommand.settings.menuItem(shortcuts: true).keyEquivalentModifierMask == [.command, .option])
        #expect(VMCommand.settings.menuItem(shortcuts: false).keyEquivalent == "")
    }

    // MARK: the obvious thing

    @Test func eachVmHasOneObviousCommand() {
        #expect(VMCommand.primary(for: vm("stopped")) == .power)  // start it
        #expect(VMCommand.primary(for: vm("suspended")) == .pause)  // resume it
        #expect(VMCommand.primary(for: vm("running")) == .open)
        #expect(VMCommand.primary(for: vm("stopped", activity: "start")) == .open)
        #expect(VMCommand.primary(for: vm("running", activity: "stop")) == .open)
    }
}

struct VMStatusTests {
    private func vm(_ state: String, activity: String? = nil) -> VmSummary {
        VmSummary(row: FakeTransport.row("w", state: state, activity: activity))!
    }

    @Test func statusSaysWhatIsHappeningInWords() {
        #expect(VMStatus.of(vm("stopped")).word == "Stopped")
        #expect(VMStatus.of(vm("running")).word == "Running")
        #expect(VMStatus.of(vm("suspended")).word == "Paused")
        #expect(VMStatus.of(vm("stopped", activity: "start")).word == "Starting…")
        #expect(VMStatus.of(vm("running", activity: "stop")).word == "Shutting Down…")
    }

    /// A paused guest is held in memory, not saved, and the status says so. It is not coloured as a warning.
    @Test func pausedSaysItIsNotSaved() {
        let paused = VMStatus.of(vm("suspended"))
        #expect(paused.note == "Not saved if openVM quits")
        #expect(paused.tone == .idle)
        #expect(VMStatus.of(vm("running")).note == nil)
    }

    @Test func anInstallShowsAsOne() {
        let row = CBOR.map([
            ("name", .text("w")), ("state", .text("stopped")), ("uuid", .text("u")), ("activity", .text("start")),
            ("installing", .bool(true)),
        ])
        #expect(VMStatus.of(VmSummary(row: row)!).word == "Installing…")
    }

    /// Status is never colour alone: every state has its own symbol, and it exists.
    @Test func everyStatusHasASymbol() {
        for summary in [vm("stopped"), vm("running"), vm("suspended"), vm("running", activity: "stop")] {
            let status = VMStatus.of(summary)
            #expect(NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil) != nil, "\(status.symbol)")
        }
    }
}

@MainActor
struct VMCommandPerformTests {
    private final class Log { var calls: [String] = [] }

    private func make(_ row: CBOR) async -> (VmSummary, VMCommandContext, FakeTransport, Log) {
        let host = FakeTransport()
        host.rows = [row]
        let model = VMListModel(transport: host)
        await model.refresh()
        let log = Log()
        let context = VMCommandContext(
            model: model, openWindow: { log.calls.append("open \($0.name)") },
            showSettings: { log.calls.append("settings \($0.name)") },
            shareFolder: { log.calls.append("share \($0.name)") },
            confirmDelete: { log.calls.append("confirm delete \($0.name)") })
        return (model.vms[0], context, host, log)
    }

    @Test func startingAlsoOpensTheWindow() async {
        let (vm, context, host, log) = await make(FakeTransport.row("a", state: "stopped"))
        await VMCommand.power.perform(on: vm, in: context)
        #expect(host.arg("start", "id") == .text("uuid-a"))
        #expect(log.calls == ["open a"])
    }

    @Test func powerShutsDownARunningGuestAndCancelsABoot() async {
        let (running, context, host, _) = await make(FakeTransport.row("a", state: "running"))
        await VMCommand.power.perform(on: running, in: context)
        #expect(host.calls.contains("stop"))
        let (booting, bootContext, bootHost, _) = await make(FakeTransport.row("b", state: "stopped", activity: "start"))
        await VMCommand.power.perform(on: booting, in: bootContext)
        #expect(bootHost.arg("stop", "id") == .text("uuid-b"))
    }

    @Test func pauseAndResumeReachTheHost() async {
        let (running, context, host, _) = await make(FakeTransport.row("a", state: "running"))
        await VMCommand.pause.perform(on: running, in: context)
        #expect(host.arg("suspend", "id") == .text("uuid-a"))
        let (paused, pausedContext, pausedHost, _) = await make(FakeTransport.row("a", state: "suspended"))
        await VMCommand.pause.perform(on: paused, in: pausedContext)
        #expect(pausedHost.arg("resume", "id") == .text("uuid-a"))
    }

    @Test func theSwitchesReachTheHost() async {
        let (vm, context, host, _) = await make(FakeTransport.row("a", state: "running"))
        await VMCommand.shareClipboard.perform(on: vm, in: context)
        #expect(host.arg("set", "clipboard-sync") == .bool(false))
        await VMCommand.acceptFiles.perform(on: vm, in: context)
        #expect(host.arg("set", "outbox") == .bool(false))
    }

    /// Delete only asks; nothing reaches the host until the person confirms.
    @Test func deleteAsksFirst() async {
        let (vm, context, host, log) = await make(FakeTransport.row("a", state: "stopped"))
        await VMCommand.delete.perform(on: vm, in: context)
        #expect(log.calls == ["confirm delete a"])
        #expect(!host.calls.contains("delete"))
    }

    /// A command that is off for a VM does nothing, however it was reached (a shortcut, a stale menu).
    @Test func aCommandThatIsOffDoesNothing() async {
        let (vm, context, host, log) = await make(FakeTransport.row("a", state: "running"))
        let before = host.calls
        await VMCommand.delete.perform(on: vm, in: context)
        await VMCommand.ejectInstaller.perform(on: vm, in: context)
        #expect(log.calls.isEmpty)
        #expect(host.calls == before)
    }

    @Test func theRestOpenTheirWindows() async {
        let (vm, context, _, log) = await make(FakeTransport.row("a", state: "running"))
        await VMCommand.open.perform(on: vm, in: context)
        await VMCommand.settings.perform(on: vm, in: context)
        await VMCommand.shareFolder.perform(on: vm, in: context)
        #expect(log.calls == ["open a", "settings a", "share a"])
    }
}
