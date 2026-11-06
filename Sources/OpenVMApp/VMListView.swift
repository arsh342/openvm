// VMListView — every VM the host knows, what each is doing, and what can be done to it.
// The state of each row comes from the host, so a change made with openvmctl shows up here.
import OpenVMCore
import SwiftUI

struct VMListView: View {
    @ObservedObject var model: VMListModel
    /// Opens a VM's window.
    let open: (VmSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            banners
            if model.vms.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.vms) { vm in
                            VMRow(vm: vm) { perform($0, on: vm) }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 300)
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
            Text("Create one with `openvmctl create <name>`.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func perform(_ action: VMAction, on vm: VmSummary) {
        switch action {
        case .open: open(vm)
        case .start: Task { await model.start(vm) }
        case .pause: Task { await model.suspend(vm) }
        case .resume: Task { await model.resume(vm) }
        case .stop: Task { await model.stop(vm) }
        case .delete: model.requestDelete(vm)
        }
    }
}

private struct VMRow: View {
    let vm: VmSummary
    let perform: (VMAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.bootMode == .windows ? "macwindow" : "terminal")
                .font(.title2).frame(width: 32).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.name).font(.headline).lineLimit(1)
                Text(VMRowLogic.subtitle(for: vm)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            status
            // A fixed, right-aligned area, so the status above stays in one column however many
            // buttons a row has.
            HStack(spacing: 8) {
                ForEach(VMRowLogic.actions(for: vm), id: \.self) { action in
                    Button(role: action == .delete ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Label(title(action), systemImage: icon(action))
                    }
                    .controlSize(.small)
                    .help(title(action))
                }
            }
            .frame(width: 290, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var status: some View {
        HStack(spacing: 6) {
            if vm.activity != nil {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(VMRowLogic.statusText(for: vm)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(minWidth: 110, alignment: .leading)
    }

    private var color: Color {
        switch vm.state {
        case .running: return .green
        case .suspended: return .orange
        case .stopped, .starting, .stopping: return .gray
        }
    }

    private func title(_ action: VMAction) -> String {
        switch action {
        case .open: return "Open"
        case .start: return "Start"
        case .pause: return "Pause"
        case .resume: return "Resume"
        case .stop: return "Stop"
        case .delete: return "Delete"
        }
    }

    private func icon(_ action: VMAction) -> String {
        switch action {
        case .open: return "macwindow"
        case .start: return "play.fill"
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .stop: return "stop.fill"
        case .delete: return "trash"
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
