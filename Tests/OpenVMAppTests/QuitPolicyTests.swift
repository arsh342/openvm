// Quitting stops every guest, so it must say so first, and must name what would be lost.
import AppKit
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct QuitPolicyTests {
    private func vm(
        _ name: String, state: String = "stopped", activity: String? = nil, installing: Bool = false,
        dropping: Bool = false
    ) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("state", .text(state)), ("uuid", .text("u-\(name)")),
            ("cpus", .uint(4)), ("memoryMB", .uint(4096)),
        ]
        if let activity { fields.append(("activity", .text(activity))) }
        if installing { fields.append(("installing", .bool(true))) }
        if dropping { fields.append(("dropping", .bool(true))) }
        return VmSummary(row: .map(fields))!
    }

    @Test func noGuestsQuitsNow() {
        #expect(quitDecision([]) == .quitNow)
        #expect(quitDecision([vm("a"), vm("b")]) == .quitNow)  // stopped VMs hold nothing
    }

    @Test func runningGuestsAreListed() {
        #expect(
            quitDecision([vm("a", state: "running"), vm("b")])
                == .confirm(running: ["a"], installing: [], dropping: []))
    }

    /// A paused guest is held in memory, not saved to disk: quitting loses that state and
    /// shuts the guest down, so it counts as running.
    @Test func suspendedCountsAsRunning() {
        #expect(
            quitDecision([vm("p", state: "suspended")])
                == .confirm(running: ["p"], installing: [], dropping: []))
    }

    @Test func quitWarnsAboutInstallsAndDrops() {
        let decision = quitDecision([
            vm("w", state: "stopped", activity: "start", installing: true),
            vm("d", state: "running", dropping: true),
            vm("r", state: "running"),
        ])
        #expect(decision == .confirm(running: ["d", "r"], installing: ["w"], dropping: ["d"]))
    }

    /// A VM that is booting holds a live guest too, even though its record still says stopped.
    @Test func aVmThatIsBootingCountsAsRunning() {
        #expect(
            quitDecision([vm("b", state: "stopped", activity: "start")])
                == .confirm(running: ["b"], installing: [], dropping: []))
    }

    @Test func theMessageNamesWhatWouldBeLost() {
        let text = quitMessage(running: ["a", "b"], installing: ["w"], dropping: ["a"])
        #expect(text.contains("a") && text.contains("b"))
        #expect(text.contains("Windows install"))
        #expect(text.contains("w"))
        #expect(text.localizedCaseInsensitiveContains("file"))  // the drop in progress
        #expect(text.contains("shut down"))
    }

    @Test func aPlainRunningGuestGetsAPlainMessage() {
        let text = quitMessage(running: ["only"], installing: [], dropping: [])
        #expect(text.contains("only"))
        #expect(!text.contains("install"))
    }

    // MARK: the Dock icon follows whether there is anything to come back to

    @Test func theDockIconStaysWhileAWindowIsOpen() {
        #expect(activationPolicy(openWindows: 1, anyGuestLive: true) == .regular)
        #expect(activationPolicy(openWindows: 2, anyGuestLive: false) == .regular)
        #expect(activationPolicy(openWindows: 0, anyGuestLive: false) == .regular)
    }

    @Test func withNoWindowAndAGuestRunningTheAppLivesInTheMenuBar() {
        #expect(activationPolicy(openWindows: 0, anyGuestLive: true) == .accessory)
    }
}
