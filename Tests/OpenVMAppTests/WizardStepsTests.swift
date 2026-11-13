// The steps the creation window lists, and where the person is in them.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct WizardStepsTests {
    private func states(_ page: CreateWizardModel.Page) -> [WizardStepState] {
        WizardSteps.all(for: page).map(\.state)
    }

    @Test func theCurrentStepIsMarkedAndEarlierOnesAreDone() {
        #expect(states(.gallery) == [.current, .upcoming, .upcoming, .upcoming, .upcoming])
        #expect(states(.resources) == [.done, .done, .current, .upcoming, .upcoming])
        #expect(states(.summary) == [.done, .done, .done, .current, .upcoming])
    }

    @Test func theRunAndItsOutcomesAreTheLastStep() {
        #expect(states(.working) == [.done, .done, .done, .done, .current])
        #expect(states(.finished) == [.done, .done, .done, .done, .done])
        #expect(states(.failed("x")) == [.done, .done, .done, .done, .current])
    }

    @Test func stepsHaveTitles() {
        #expect(
            WizardSteps.all(for: .gallery).map(\.title) == [
                "System", "Installer", "Resources", "Summary", "Install",
            ])
    }
}

struct WindowsWizardStepsTests {
    @Test func windowsHasAnAccountStep() {
        let steps = WizardSteps.all(for: .account, os: .windows)
        #expect(steps.map(\.title) == ["System", "Installer", "Resources", "Account", "Summary", "Install"])
        #expect(steps.map(\.state) == [.done, .done, .done, .current, .upcoming, .upcoming])
    }

    @Test func linuxHasNone() {
        #expect(!WizardSteps.all(for: .gallery, os: .linuxISO).map(\.title).contains("Account"))
    }
}
