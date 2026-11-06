// What the Machine menu offers for the VM in front: each command's title, whether it is live,
// and whether it is ticked. Plain functions of the VM's summary.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct MachineMenuLogicTests {
    private func vm(_ state: String, activity: String? = nil, clipboardSync: Bool? = nil) -> VmSummary {
        VmSummary(row: FakeTransport.row("w", state: state, activity: activity, clipboardSync: clipboardSync))!
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

    @Test func nothingIsLiveWhileTheHostIsBusyWithTheVm() {
        let busy = vm("running", activity: "stop")
        #expect(MachineMenuLogic.item(.power, for: busy).enabled == false)
        #expect(MachineMenuLogic.item(.pause, for: busy).enabled == false)
    }

    @Test func fullScreenNeedsAGuestToShow() {
        #expect(MachineMenuLogic.item(.fullScreen, for: vm("running")).enabled)
        #expect(!MachineMenuLogic.item(.fullScreen, for: vm("stopped")).enabled)
    }

    @Test func clipboardIsTickedWhenSharing() {
        #expect(MachineMenuLogic.item(.clipboard, for: vm("running")).checked)
        #expect(!MachineMenuLogic.item(.clipboard, for: vm("running", clipboardSync: false)).checked)
    }

    @Test func settingsAndSharingAreAlwaysThereForAVm() {
        for state in ["stopped", "running", "suspended"] {
            #expect(MachineMenuLogic.item(.settings, for: vm(state)).enabled)
            #expect(MachineMenuLogic.item(.shareFolder, for: vm(state)).enabled)
        }
    }

    @Test func withNoVmInFrontEverythingIsOff() {
        for command in MachineCommand.allCases {
            #expect(!MachineMenuLogic.item(command, for: nil).enabled, "\(command)")
        }
    }
}

@MainActor
struct LibrarySelectionTests {
    private func model(_ names: [String]) async -> VMListModel {
        let host = FakeTransport()
        host.rows = names.map { FakeTransport.row($0) }
        let model = VMListModel(transport: host)
        await model.refresh()
        return model
    }

    @Test func nothingChosenMeansTheFirst() async {
        let model = await model(["a", "b"])
        #expect(model.selectedVM?.name == "a")
    }

    @Test func aChoiceIsKept() async {
        let model = await model(["a", "b"])
        model.selection = "uuid-b"
        await model.refresh()
        #expect(model.selectedVM?.name == "b")
    }

    @Test func aDeletedChoiceFallsBackToTheFirst() async {
        let model = await model(["a", "b"])
        model.selection = "uuid-gone"
        #expect(model.selectedVM?.name == "a")
    }

    @Test func noVmsMeansNoSelection() async {
        let model = await model([])
        #expect(model.selectedVM == nil)
    }
}
