// Telling a guest's restart from its power-off, from what the kernel said on the console.
import Foundation
import Testing

@testable import OpenVMHost

struct StopIntentTests {
    @Test func theAgentsGoingDownLineIsRead() {
        #expect(stopIntent(consoleTail: "openvm-tools: going down: reboot\n") == .restart)
        #expect(stopIntent(consoleTail: "openvm-tools: going down: shutdown\n") == .powerOff)
        #expect(stopIntent(consoleTail: "openvm-tools: going down: \n") == .unknown)
    }

    @Test func linuxRestartLineMeansRestart() {
        let tail = "openvm-tools: stopping\n[  12.3] reboot: Restarting system\n"
        #expect(stopIntent(consoleTail: tail) == .restart)
    }

    @Test func linuxPowerDownMeansPowerOff() {
        #expect(stopIntent(consoleTail: "reboot: Power down\n") == .powerOff)
        #expect(stopIntent(consoleTail: "reboot: System halted\n") == .powerOff)
    }

    @Test func theLastWordWins() {
        #expect(stopIntent(consoleTail: "reboot: Restarting system\nlater\nreboot: Power down\n") == .powerOff)
    }

    @Test func silenceIsUnknownAndUnknownNeverRestarts() {
        #expect(stopIntent(consoleTail: "") == .unknown)
        #expect(stopIntent(consoleTail: "kernel panic - not syncing\n") == .unknown)
        #expect(!StopIntent.unknown.restarts)
        #expect(!StopIntent.powerOff.restarts)
        #expect(StopIntent.restart.restarts)
    }

    /// A guest that restarts as soon as it boots must not be restarted for ever.
    @Test func restartsAreRationed() {
        var budget = RestartBudget(limit: 3, window: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        let first = budget.allow(at: t0)
        let second = budget.allow(at: t0 + 5)
        let third = budget.allow(at: t0 + 10)
        let fourth = budget.allow(at: t0 + 15)
        let later = budget.allow(at: t0 + 100)  // the old ones have aged out
        #expect(first && second && third)
        #expect(!fourth)
        #expect(later)
    }
}
