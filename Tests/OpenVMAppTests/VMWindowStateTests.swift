// What a VM window shows for each state the host can report.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct VMWindowStateTests {
    private func vm(_ state: String, activity: String? = nil) -> VmSummary {
        VmSummary(row: FakeTransport.row("w", state: state, activity: activity))!
    }

    @Test func stateFollowsSummary() {
        // (host state, activity, has a live machine) -> what the window shows
        #expect(VMWindowState.from(vm("stopped"), hasMachine: false) == .stopped)
        #expect(VMWindowState.from(vm("stopped", activity: "start"), hasMachine: true) == .busy("Starting…"))
        #expect(VMWindowState.from(vm("stopped", activity: "start"), hasMachine: false) == .busy("Starting…"))
        #expect(VMWindowState.from(vm("running"), hasMachine: true) == .running)
        #expect(VMWindowState.from(vm("running", activity: "stop"), hasMachine: true) == .busy("Shutting down…"))
        #expect(VMWindowState.from(vm("running", activity: "suspend"), hasMachine: true) == .busy("Pausing…"))
        #expect(VMWindowState.from(vm("suspended"), hasMachine: true) == .paused)
        #expect(VMWindowState.from(vm("suspended", activity: "resume"), hasMachine: true) == .busy("Resuming…"))
    }

    @Test func aRunningVmWithNoMachineIsAFault() {
        if case .failed = VMWindowState.from(vm("running"), hasMachine: false) {
        } else {
            Issue.record("expected .failed")
        }
    }

    @Test func onlyRunningAndBootingShowTheScreen() {
        #expect(VMWindowState.running.showsScreen)
        #expect(VMWindowState.busy("Starting…").showsScreen)
        #expect(VMWindowState.paused.showsScreen)  // a paused guest keeps its last frame
        #expect(!VMWindowState.stopped.showsScreen)
        #expect(!VMWindowState.failed("x").showsScreen)
    }
}
