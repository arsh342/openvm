// WizardSteps — the steps listed in the creation window's sidebar, and where the person is in them.
import Foundation

enum WizardStepState: Equatable { case done, current, upcoming }

struct WizardStep: Equatable, Identifiable {
    let title: String
    let symbol: String
    let state: WizardStepState
    var id: String { title }
}

enum WizardSteps {
    private static let steps: [(title: String, symbol: String)] = [
        ("System", "desktopcomputer"), ("Source", "opticaldisc"), ("Resources", "cpu"),
        ("Summary", "list.bullet.rectangle"), ("Install", "arrow.down.circle"),
    ]

    static func all(for page: CreateWizardModel.Page) -> [WizardStep] {
        let current: Int
        var allDone = false
        switch page {
        case .os: current = 0
        case .source: current = 1
        case .resources: current = 2
        case .summary: current = 3
        case .working, .failed: current = 4
        case .finished:
            current = 4
            allDone = true
        }
        return steps.enumerated().map { index, step in
            let state: WizardStepState = allDone || index < current ? .done : (index == current ? .current : .upcoming)
            return WizardStep(title: step.title, symbol: step.symbol, state: state)
        }
    }
}
