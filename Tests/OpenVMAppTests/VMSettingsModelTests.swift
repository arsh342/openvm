// The settings a person can change for a VM, and what is allowed when.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
struct VMSettingsModelTests {
    private func model(
        _ vm: VmSummary, host: FakeTransport = FakeTransport()
    ) async -> (VMSettingsModel, FakeTransport) {
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        let model = VMSettingsModel(vm: vm, transport: host)
        await model.load()
        return (model, host)
    }

    @Test func resourcesLockWhileRunning() async {
        let (running, _) = await model(FakeTransport.summary(state: "running"))
        #expect(!running.canEditResources)
        running.cpus = 2
        running.memoryMB = 2048
        #expect(running.changes().isEmpty)  // a running VM ignores resource edits
        let (stopped, _) = await model(FakeTransport.summary(state: "stopped"))
        #expect(stopped.canEditResources)
        stopped.cpus = 2
        #expect(stopped.changes().contains { $0.key == "cpus" && $0.value == .uint(2) })
    }

    @Test func aVmTheHostIsBusyWithCannotBeResized() async {
        let busy = VmSummary(row: FakeTransport.row("w", state: "stopped", activity: "start"))!
        let (model, _) = await model(busy)
        #expect(!model.canEditResources)
    }

    @Test func onlyWhatChangedIsSent() async {
        let (model, host) = await model(FakeTransport.summary(cpus: 4, memoryMB: 4096, timezone: "UTC"))
        #expect(model.changes().isEmpty)
        model.memoryMB = 8192
        model.timezone = "Europe/Berlin"
        let keys = Set(model.changes().map(\.key))
        #expect(keys == ["memoryMB", "tz"])
        let ok = await model.apply()
        #expect(ok)
        #expect(host.arg("set", "memoryMB") == .uint(8192))
        #expect(host.arg("set", "tz") == .text("Europe/Berlin"))
        #expect(host.arg("set", "cpus") == nil)
        #expect(host.arg("set", "id") == .text("uuid-w"))
    }

    @Test func valuesAboveHostLimitsAreRefused() async {
        let (model, host) = await model(FakeTransport.summary(cpus: 4, memoryMB: 4096))
        model.cpus = 64
        #expect(model.validationProblem?.contains("8") == true)  // this Mac has 8
        #expect(await !model.apply())
        #expect(!host.calls.contains("set"))
        model.cpus = 4
        model.memoryMB = 65536
        #expect(model.validationProblem?.contains("16384") == true)
    }

    @Test func choicesStayWithinWhatTheMacHas() async {
        let (model, _) = await model(FakeTransport.summary(cpus: 4, memoryMB: 4096))
        #expect(model.cpuChoices == Array(1...8))
        #expect(model.memoryChoices.max()! <= 16384)
        #expect(model.memoryChoices.contains(4096))
        #expect(model.memoryChoices == model.memoryChoices.sorted())
    }

    @Test func aCurrentValueOutsideTheUsualStepsStaysSelectable() async {
        let (model, _) = await model(FakeTransport.summary(memoryMB: 5000))
        #expect(model.memoryChoices.contains(5000))
    }

    @Test func shareErrorsAreShown() async {
        let host = FakeTransport()
        host.fail("share-add", with: HostError.remote("hostPath must be an existing directory"))
        let (model, _) = await model(FakeTransport.summary(state: "running"), host: host)
        await model.addShare(hostPath: "/nope")
        #expect(model.error == "hostPath must be an existing directory")
    }

    @Test func sharesAreListedAndRemovedByHostPath() async {
        let host = FakeTransport()
        host.respond("share-list", with: [
            ("shares", .array([.map([("hostPath", .text("/Users/me/Projects")), ("guestPath", .text("/mnt/openvm/Projects"))])]))
        ])
        let (model, _) = await model(FakeTransport.summary(state: "running"), host: host)
        #expect(model.shares == [VMSettingsModel.Share(hostPath: "/Users/me/Projects", guestPath: "/mnt/openvm/Projects")])
        await model.removeShare(model.shares[0])
        #expect(host.arg("share-remove", "hostPath") == .text("/Users/me/Projects"))
    }

    @Test func soundIsOnlyOfferedForARunningWindowsGuest() async {
        let (linux, _) = await model(FakeTransport.summary(state: "running", bootMode: "linux"))
        let (stopped, _) = await model(FakeTransport.summary(state: "stopped", bootMode: "windows"))
        let (windows, _) = await model(FakeTransport.summary(state: "running", bootMode: "windows"))
        #expect(!linux.soundAvailable)
        #expect(!stopped.soundAvailable)  // the agent that does the work is not there to ask
        #expect(windows.soundAvailable)
    }

    @Test func testModeNeedsExplicitConsent() async {
        let (model, host) = await model(FakeTransport.summary(state: "running", bootMode: "windows"))
        await model.enableSound(consented: false)
        #expect(!host.values("audio", "op").contains(.text("enable")))  // nothing is sent without consent
        #expect(model.error != nil)
        model.error = nil
        await model.enableSound(consented: true)
        #expect(host.values("audio", "op").contains(.text("enable")))
        #expect(host.values("audio", "testMode") == [.bool(true)])  // sent with the enable, and only with it
    }

    @Test func theWarningSaysWhatTestModeCosts() {
        let warning = VMSettingsModel.testModeWarning
        #expect(warning.contains("Test Mode"))
        #expect(warning.contains("signature"))
        #expect(warning.contains("watermark"))
        #expect(warning.localizedCaseInsensitiveContains("restart"))
    }

    @Test func turningSoundOffNeedsNoConsent() async {
        let (model, host) = await model(FakeTransport.summary(state: "running", bootMode: "windows"))
        await model.disableSound()
        #expect(host.values("audio", "op").contains(.text("disable")))
        #expect(host.values("audio", "testMode").isEmpty)
    }
}
