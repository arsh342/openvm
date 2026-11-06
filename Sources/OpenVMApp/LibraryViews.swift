// LibraryViews — the library window's two panes: a Settings-style sidebar (search, the VMs, a way to make
// a new one) and the page for what is chosen: every VM as cards, or one VM's page.
import OpenVMCore
import SwiftUI

struct LibrarySidebarView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var nav: LibraryNav
    let newVM: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField.padding(.horizontal, 14).padding(.top, 52).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarRow(selected: nav.selection == .all, choose: { nav.selection = .all }) {
                        SidebarIcon(symbol: "square.grid.2x2.fill", color: .gray)
                        Text("All Virtual Machines")
                    }
                    Text("Virtual Machines")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                    ForEach(LibraryNav.visible(model.vms, search: nav.search)) { vm in
                        sidebarRow(selected: nav.selection == .vm(vm.uuid), choose: { nav.selection = .vm(vm.uuid) }) {
                            SidebarIcon(
                                symbol: vm.bootMode == .windows ? "macwindow" : "terminal",
                                color: vm.bootMode == .windows ? .blue : .indigo)
                            Text(vm.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if vm.activity != nil {
                                ProgressView().controlSize(.mini)
                            } else {
                                Circle().fill(LibraryColors.dot(for: vm)).frame(width: 7, height: 7)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            Button(action: newVM) {
                HStack(spacing: 10) {
                    SidebarIcon(symbol: "plus", color: .green)
                    Text("New Virtual Machine…")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    /// A row in the Settings style: icon and title, filled with the accent colour when chosen.
    private func sidebarRow<Content: View>(
        selected: Bool, choose: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) { content() }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: Binding(get: { nav.search }, set: { nav.search = $0 }))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.08)))
    }
}

enum LibraryColors {
    static func dot(for vm: VmSummary) -> Color {
        switch vm.state {
        case .running: return .green
        case .suspended: return .orange
        case .stopped, .starting, .stopping: return .gray
        }
    }
}

/// The right-hand pane: banners, then the chosen page. It also owns the delete confirmation.
struct LibraryDetailView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var nav: LibraryNav
    @ObservedObject var thumbnails: ThumbnailStore
    let open: (VmSummary) -> Void
    let settings: (VmSummary) -> Void
    let newVM: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            banners
            page
        }
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
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

    @ViewBuilder private var page: some View {
        switch LibraryNav.resolve(nav.selection, in: model.vms) {
        case .all:
            VMListView(
                model: model, thumbnails: thumbnails, open: { open($0) }, settings: { settings($0) }, newVM: newVM)
        case .vm(let uuid):
            if let vm = model.vm(uuid: uuid) {
                VMPage(vm: vm, image: thumbnails.image(for: uuid)) { perform($0, on: vm) }
            }
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

/// One VM's page, laid out like a Settings pane: a header, then grouped rows.
private struct VMPage: View {
    let vm: VmSummary
    let image: NSImage?
    let perform: (VMAction) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                group(actionRows)
                group(detailRows)
            }
            .padding(.horizontal, 24).padding(.top, 44).padding(.bottom, 24)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: vm.bootMode == .windows
                                ? [Color(red: 0.10, green: 0.30, blue: 0.62), Color(red: 0.05, green: 0.14, blue: 0.34)]
                                : [Color(red: 0.16, green: 0.18, blue: 0.30), Color(red: 0.07, green: 0.08, blue: 0.16)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: vm.bootMode == .windows ? "macwindow" : "terminal")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: 260, height: 163)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            Text(vm.name).font(.title.weight(.bold))
            HStack(spacing: 6) {
                if vm.activity != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(LibraryColors.dot(for: vm)).frame(width: 9, height: 9)
                }
                Text(VMRowLogic.statusText(for: vm)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private var actionRows: [AnyView] {
        VMRowLogic.actions(for: vm).map { action in
            AnyView(
                Button { perform(action) } label: {
                    HStack(spacing: 12) {
                        SidebarIcon(symbol: action.symbol, color: color(for: action))
                        Text(action.title).foregroundStyle(action == .delete ? Color.red : Color.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain))
        }
    }

    private var detailRows: [AnyView] {
        VMRowLogic.details(for: vm).map { row in
            AnyView(
                HStack {
                    Text(row.label)
                    Spacer()
                    Text(row.value).foregroundStyle(.secondary)
                })
        }
    }

    private func color(for action: VMAction) -> Color {
        switch action {
        case .open: return .blue
        case .start, .resume: return .green
        case .pause: return .orange
        case .stop: return .gray
        case .settings: return .gray
        case .delete: return .red
        }
    }

    /// Rows in a rounded group with hairlines between them, as in a Settings pane.
    private func group(_ rows: [AnyView]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().padding(.leading, 14) }
                row.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

struct Banner: View {
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
