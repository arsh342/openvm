// VMListView — the library: every VM in a sidebar, and the chosen one's state, details and actions on
// the right. The state of each VM comes from the host, so a change made with openvmctl shows up here.
import OpenVMCore
import SwiftUI

struct VMListView: View {
    @ObservedObject var model: VMListModel
    /// Opens a VM's window.
    let open: (VmSummary) -> Void
    /// Opens a VM's settings.
    let settings: (VmSummary) -> Void
    /// Starts the creation wizard.
    let newVM: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            banners
            HStack(spacing: 0) {
                sidebar.frame(width: 240)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .confirmationDialog(
            model.pendingDelete.map { VMRowLogic.deleteConfirmation(for: $0).title } ?? "", isPresented: isDeleting,
            titleVisibility: .visible, presenting: model.pendingDelete
        ) { vm in
            Button("Delete", role: .destructive) { Task { await model.confirmDelete(vm) } }
            Button("Cancel", role: .cancel) { model.cancelDelete() }
        } message: { vm in
            Text(VMRowLogic.deleteConfirmation(for: vm).message)
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.cancelDelete() } })
    }

    // MARK: sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Text("Virtual Machines")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            if model.vms.isEmpty {
                Text("None yet").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.vms) { vm in
                            SidebarRow(vm: vm, selected: model.selectedVM?.uuid == vm.uuid)
                                .contentShape(Rectangle())
                                .onTapGesture { model.selection = vm.uuid }
                                .onTapGesture(count: 2) { open(vm) }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            Divider()
            Button(action: newVM) {
                Label("New VM…", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        if let vm = model.selectedVM {
            VMDetail(vm: vm) { perform($0, on: vm) }
        } else {
            emptyState
        }
    }

    @ViewBuilder private var banners: some View {
        if let problem = model.hostProblem {
            Banner(text: problem, systemImage: "bolt.horizontal.circle", tint: .red, dismiss: nil)
        }
        if let error = model.lastError {
            Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange) { model.lastError = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No virtual machines").font(.title3.weight(.medium))
            Text("Create one to get started.").foregroundStyle(.secondary)
            Button("New VM…", action: newVM).padding(.top, 4)
        }
        .padding(32)
    }

    private func perform(_ action: VMAction, on vm: VmSummary) {
        switch action {
        case .open: open(vm)
        case .settings: settings(vm)
        case .start: Task { await model.start(vm) }
        case .pause: Task { await model.suspend(vm) }
        case .resume: Task { await model.resume(vm) }
        case .stop: Task { await model.stop(vm) }
        case .delete: model.requestDelete(vm)
        }
    }
}

// MARK: pieces

private struct SidebarRow: View {
    let vm: VmSummary
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: vm.bootMode == .windows ? "macwindow" : "terminal")
                .frame(width: 22).foregroundStyle(selected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.name).lineLimit(1).foregroundStyle(selected ? Color.white : Color.primary)
                HStack(spacing: 5) {
                    if vm.activity != nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(selected ? Color.white : StatusColor.color(for: vm)).frame(width: 6, height: 6)
                    }
                    Text(VMRowLogic.statusText(for: vm)).font(.caption)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
    }
}

private struct VMDetail: View {
    let vm: VmSummary
    let perform: (VMAction) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                actions
                details
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: vm.bootMode == .windows ? "macwindow" : "terminal")
                .font(.system(size: 30)).foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name).font(.title.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if vm.activity != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle().fill(StatusColor.color(for: vm)).frame(width: 9, height: 9)
                    }
                    Text(VMRowLogic.statusText(for: vm)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        let all = VMRowLogic.actions(for: vm)
        let primary = all.first { $0 == .start || $0 == .open || $0 == .resume }
        return HStack(spacing: 10) {
            ForEach(all, id: \.self) { action in
                if action == primary {
                    Button { perform(action) } label: { Label(action.title, systemImage: action.symbol) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(role: action == .delete ? .destructive : nil) { perform(action) } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                }
            }
        }
        .controlSize(.large)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(VMRowLogic.details(for: vm).enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value)
                }
                .padding(.vertical, 9).padding(.horizontal, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

private enum StatusColor {
    static func color(for vm: VmSummary) -> Color {
        switch vm.state {
        case .running: return .green
        case .suspended: return .orange
        case .stopped, .starting, .stopping: return .gray
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).lineLimit(3)
            Spacer()
            if let dismiss { Button("Dismiss", action: dismiss).controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}

extension VMAction {
    var title: String {
        switch self {
        case .open: return "Open"
        case .start: return "Start"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Shut Down"
        case .settings: return "Settings"
        case .delete: return "Delete"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "macwindow"
        case .start: return "play.fill"
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .stop: return "power"
        case .settings: return "gearshape"
        case .delete: return "trash"
        }
    }
}
