// Which toolbar buttons are live, and what they say, for each state of a VM.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct VMToolbarLogicTests {
    private func vm(_ state: String, activity: String? = nil) -> VmSummary {
        VmSummary(row: FakeTransport.row("w", state: state, activity: activity))!
    }

    @Test func eachStateOffersItsOwnButtons() {
        let stopped = VMToolbarLogic.state(for: vm("stopped"))
        #expect(stopped.power == .start)
        #expect(stopped.pause == .disabled)  // nothing to pause
        #expect(!stopped.fullScreenEnabled)

        let running = VMToolbarLogic.state(for: vm("running"))
        #expect(running.power == .shutDown)
        #expect(running.pause == .pause)
        #expect(running.fullScreenEnabled)

        let paused = VMToolbarLogic.state(for: vm("suspended"))
        #expect(paused.power == .shutDown)
        #expect(paused.pause == .resume)
        #expect(paused.fullScreenEnabled)
    }

    /// A boot in progress can be cancelled, and nothing else can be done to it.
    @Test func aBootingVmCanOnlyBeCancelled() {
        let booting = VMToolbarLogic.state(for: vm("stopped", activity: "start"))
        #expect(booting.power == .cancel)
        #expect(booting.pause == .disabled)
        #expect(booting.fullScreenEnabled)  // the screen is already showing the boot
    }

    @Test func anyOtherActivityLocksThePowerAndPauseButtons() {
        for activity in ["stop", "suspend", "resume", "delete"] {
            let state = VMToolbarLogic.state(for: vm("running", activity: activity))
            #expect(state.power == .disabled, "\(activity)")
            #expect(state.pause == .disabled, "\(activity)")
        }
    }

    @Test func buttonsSayWhatTheyDo() {
        #expect(PowerButton.start.title == "Start")
        #expect(PowerButton.shutDown.title == "Shut Down")
        #expect(PowerButton.cancel.title == "Cancel Start")
        #expect(PauseButton.pause.title == "Pause")
        #expect(PauseButton.resume.title == "Resume")
    }
}
