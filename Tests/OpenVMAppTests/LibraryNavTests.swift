// Which page the library shows, and which VMs its sidebar lists.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct LibraryNavTests {
    private func vms(_ names: [String]) -> [VmSummary] {
        names.map { VmSummary(row: FakeTransport.row($0))! }
    }

    @Test func searchFindsVmsByNamePartAndCase() {
        let all = vms(["Ubuntu-Lab", "windows-11", "scratch"])
        #expect(LibraryNav.visible(all, search: "").map(\.name) == ["Ubuntu-Lab", "windows-11", "scratch"])
        #expect(LibraryNav.visible(all, search: "WIN").map(\.name) == ["windows-11"])
        #expect(LibraryNav.visible(all, search: "  lab ").map(\.name) == ["Ubuntu-Lab"])
        #expect(LibraryNav.visible(all, search: "zzz").isEmpty)
    }

    @Test func aChosenVmIsShownWhileItExists() {
        let all = vms(["a", "b"])
        #expect(LibraryNav.resolve(.vm("uuid-b"), in: all) == .vm("uuid-b"))
    }

    @Test func aVmThatIsGoneFallsBackToTheOverview() {
        let all = vms(["a"])
        #expect(LibraryNav.resolve(.vm("uuid-gone"), in: all) == .all)
        #expect(LibraryNav.resolve(.all, in: all) == .all)
    }
}

struct WizardStepsTests {
    private func states(_ page: CreateWizardModel.Page) -> [WizardStepState] {
        WizardSteps.all(for: page).map(\.state)
    }

    @Test func theCurrentStepIsMarkedAndEarlierOnesAreDone() {
        #expect(states(.os) == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
        #expect(states(.resources) == [.done, .done, .current, .upcoming, .upcoming])
        #expect(states(.summary) == [.done, .done, .done, .current, .upcoming])
    }

    @Test func theRunAndItsOutcomesAreTheLastStep() {
        #expect(states(.working) == [.done, .done, .done, .done, .current])
        #expect(states(.finished) == [.done, .done, .done, .done, .done])
        #expect(states(.failed("x")) == [.done, .done, .done, .done, .current])
    }

    @Test func stepsHaveTitles() {
        #expect(WizardSteps.all(for: .os).map(\.title) == ["System", "Source", "Resources", "Summary", "Install"])
    }
}
