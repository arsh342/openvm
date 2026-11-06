// StatusPopoverView — what the menu-bar icon shows: every VM, one button each, and a way
// back to the library. It is how a running VM stays reachable with every window closed.
import OpenVMCore
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var model: VMListModel
    let act: (VMAction, VmSummary) -> Void
    let showLibrary: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("openVM").font(.headline).padding(12)
            Divider()
            if let problem = model.hostProblem {
                Text(problem).font(.callout).foregroundStyle(.red).padding(12)
                Divider()
            }
            if model.vms.isEmpty {
                Text("No virtual machines").foregroundStyle(.secondary).padding(12)
            } else {
                ForEach(model.vms) { vm in
                    PopoverRow(vm: vm) { act(VMRowLogic.primaryAction(for: vm), vm) }
                    Divider()
                }
            }
            HStack {
                Button("Show Library", action: showLibrary)
                Spacer()
                Button("Quit openVM", action: quit)
            }
            .controlSize(.small)
            .padding(10)
        }
        .frame(width: 340)
    }
}

private struct PopoverRow: View {
    let vm: VmSummary
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).font(.body).lineLimit(1)
                Text(VMRowLogic.statusText(for: vm)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(label, action: perform).controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var label: String {
        switch VMRowLogic.primaryAction(for: vm) {
        case .start: return "Start"
        case .resume: return "Resume"
        default: return "Open"
        }
    }

    private var dot: Color {
        if vm.activity != nil { return .blue }
        switch vm.state {
        case .running: return .green
        case .suspended: return .orange
        case .stopped, .starting, .stopping: return .gray
        }
    }
}
