// StatusPopoverView — what the menu-bar icon shows: every VM with its current settings, one button
// each, and a way back to the library. It is how a running VM stays reachable with every window closed.
import Combine
import OpenVMCore
import SwiftUI

/// Which VMs' settings are open in the popover. Kept here, not in the view, because the toolchain
/// cannot build SwiftUI's @State macro.
@MainActor
final class PopoverState: ObservableObject {
    @Published private(set) var expanded: Set<String> = []

    func toggle(_ uuid: String) {
        if expanded.contains(uuid) { expanded.remove(uuid) } else { expanded.insert(uuid) }
    }
}

struct StatusPopoverView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var state: PopoverState
    let act: (VMAction, VmSummary) -> Void
    let showLibrary: () -> Void
    let quit: () -> Void

    init(
        model: VMListModel, state: PopoverState = PopoverState(),
        act: @escaping (VMAction, VmSummary) -> Void, showLibrary: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.model = model
        self.state = state
        self.act = act
        self.showLibrary = showLibrary
        self.quit = quit
    }

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
                    PopoverRow(
                        vm: vm, expanded: state.expanded.contains(vm.uuid),
                        toggle: { state.toggle(vm.uuid) },
                        perform: { act(VMRowLogic.primaryAction(for: vm), vm) },
                        settings: { act(.settings, vm) },
                        setClipboard: { on in Task { await model.setClipboardSync(vm, on) } },
                        setOutbox: { on in Task { await model.setOutbox(vm, on) } })
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
    let expanded: Bool
    let toggle: () -> Void
    let perform: () -> Void
    let settings: () -> Void
    let setClipboard: (Bool) -> Void
    let setOutbox: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide settings" : "Show settings")
                Circle().fill(dot).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.name).font(.body).lineLimit(1)
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(label, action: perform).controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if expanded { settingsPanel }
        }
    }

    /// "Running · 4 CPUs · 8 GB": the state and the sizes, always visible.
    private var summary: String {
        let rows = Dictionary(uniqueKeysWithValues: VMRowLogic.details(for: vm).map { ($0.label, $0.value) })
        return [VMRowLogic.statusText(for: vm), "\(rows["CPUs"] ?? "") CPUs", rows["Memory"] ?? ""]
            .joined(separator: " · ")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(VMRowLogic.details(for: vm).enumerated()), id: \.offset) { _, row in
                if row.label != "Clipboard sharing" && row.label != "Receiving files from the VM" {
                    HStack {
                        Text(row.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value)
                    }
                    .font(.caption)
                }
            }
            Toggle("Share clipboard", isOn: Binding(get: { vm.clipboardSync }, set: setClipboard))
            Toggle("Accept files the VM sends", isOn: Binding(get: { vm.outbox }, set: setOutbox))
            HStack {
                Spacer()
                Button("Settings…", action: settings).controlSize(.small)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
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
