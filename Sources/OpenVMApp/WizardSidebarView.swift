// WizardSidebarView — the creation window's sidebar: the steps, with where you are. Like a Settings
// sidebar it is a list of coloured-icon rows; here the rows show progress and are not clickable (the
// Back and Next buttons move you).
import SwiftUI

struct WizardSidebarView: View {
    @ObservedObject var model: CreateWizardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Virtual Machine")
                .font(.headline)
                .padding(.horizontal, 18).padding(.top, 54).padding(.bottom, 10)
            ForEach(WizardSteps.all(for: model.page)) { step in
                row(step)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func row(_ step: WizardStep) -> some View {
        let current = step.state == .current
        return HStack(spacing: 10) {
            SidebarIcon(symbol: step.state == .done ? "checkmark" : step.symbol, color: color(step.state))
            Text(step.title)
                .foregroundStyle(current ? Color.white : (step.state == .upcoming ? Color.secondary : Color.primary))
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Color.accentColor : Color.clear))
    }

    private func color(_ state: WizardStepState) -> Color {
        switch state {
        case .done: return .green
        case .current: return .blue
        case .upcoming: return .gray
        }
    }
}
