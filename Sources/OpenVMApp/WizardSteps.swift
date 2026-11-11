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
    /// Only Windows has an account to choose: a Linux installer asks for its own.
    static func all(for page: CreateWizardModel.Page, os: CreateWizardModel.OS = .linuxISO) -> [WizardStep] {
        var steps: [(title: String, symbol: String, page: CreateWizardModel.Page)] = [
            ("System", "desktopcomputer", .os), ("Source", "opticaldisc", .source), ("Resources", "cpu", .resources),
        ]
        if os == .windows { steps.append(("Account", "person.fill", .account)) }
        steps.append(("Summary", "list.bullet.rectangle", .summary))
        steps.append(("Install", "arrow.down.circle", .working))
        let current: Int
        var allDone = false
        switch page {
        case .working, .failed: current = steps.count - 1
        case .finished:
            current = steps.count - 1
            allDone = true
        default: current = steps.firstIndex { $0.page == page } ?? 0
        }
        return steps.enumerated().map { index, step in
            let state: WizardStepState = allDone || index < current ? .done : (index == current ? .current : .upcoming)
            return WizardStep(title: step.title, symbol: step.symbol, state: state)
        }
    }
}
