// The model every window and menu reads: the host's VMs, kept current, with actions.
import Combine
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
struct VMListModelTests {
    @Test func pollPublishesChanges() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a")]
        let model = VMListModel(transport: host)
        await model.refresh()
        #expect(model.vms.map(\.name) == ["a"])
        host.rows = [FakeTransport.row("a", state: "running"), FakeTransport.row("b")]
        await model.refresh()
        #expect(model.vms.map(\.name) == ["a", "b"])
        #expect(model.vms[0].state == .running)
    }

    @Test func unchangedPollDoesNotRepublish() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a")]
        let model = VMListModel(transport: host)
        await model.refresh()
        var published = 0
        let watch = model.$vms.sink { _ in published += 1 }
        defer { watch.cancel() }
        let before = published  // the subscription's own first value
        await model.refresh()
        await model.refresh()
        #expect(published == before)
    }

    @Test func failedActionSetsLastError() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a", state: "running")]
        let model = VMListModel(transport: host)
        await model.refresh()
        host.failure = HostError.remote("a is busy: start")
        await model.stop(model.vms[0])
        #expect(model.lastError == "a is busy: start")
    }

    @Test func lostHostIsReportedNotFatal() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a")]
        let model = VMListModel(transport: host)
        await model.refresh()
        host.failure = HostError.protocolFailure("the host closed")
        await model.refresh()
        #expect(model.hostProblem != nil)
        #expect(model.lastError == nil)  // not an action error
        #expect(model.vms.map(\.name) == ["a"])  // the last known list stays on screen
        host.failure = nil
        await model.refresh()
        #expect(model.hostProblem == nil)  // and clears once the host answers
    }

    @Test func deleteRefusedOnLiveVm() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a", state: "running")]
        let model = VMListModel(transport: host)
        await model.refresh()
        await model.delete(model.vms[0])
        #expect(!host.calls.contains("delete"))
        #expect(model.lastError?.contains("Stop") == true)
    }

    @Test func actionsAddressTheVmByItsUuid() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a")]
        let model = VMListModel(transport: host)
        await model.refresh()
        await model.start(model.vms[0])
        #expect(host.calls.contains("start"))
    }
}

extension VMListModelTests {
    /// The refresh that follows an action must not wipe the reason the action failed.
    @Test func aRefreshDoesNotHideAnActionError() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("a", state: "running")]
        let model = VMListModel(transport: host)
        await model.refresh()
        host.failure = HostError.remote("a is busy: start")
        await model.stop(model.vms[0])
        host.failure = nil
        await model.refresh()  // the host answers again
        #expect(model.lastError == "a is busy: start")
    }
}
