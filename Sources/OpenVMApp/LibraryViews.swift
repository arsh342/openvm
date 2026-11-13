// LibraryViews — the library window's three panes, all standard controls: a sidebar of groups, a
// sortable table of VMs, and a detail pane for the selected one. Keyboard focus, arrow keys and
// VoiceOver come with the controls. None keeps state of its own: it is in LibraryNav.
import OpenVMCore
import SwiftUI

// MARK: status

/// A VM's status as a symbol and a word, never colour alone.
struct StatusBadge: View {
    let status: VMStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(status.word)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch status.tone {
        case .running: return .green
        case .busy: return .orange
        case .idle: return .secondary
        }
    }
}

/// The neutral glyph for what a VM runs. No vendor logos.
enum SystemGlyph {
    static func symbol(for vm: VmSummary) -> String { vm.bootMode == .windows ? "macwindow" : "terminal" }
}

// MARK: sidebar

struct LibrarySidebarView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var nav: LibraryNav

    var body: some View {
        List(selection: $nav.group) {
            Section("Virtual Machines") {
                ForEach(LibraryGroup.allCases, id: \.self) { group in
                    Label(group.title, systemImage: group.symbol)
                        .badge(group == .running ? LibraryNav.members(model.vms, of: .running).count : 0)
                        .tag(group)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: table

struct VMTableView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var nav: LibraryNav
    /// Carries out a command for a VM.
    let run: (VMCommand, VmSummary) -> Void
    /// Starts the creation wizard.
    let newVM: (NewVMStart) -> Void
    /// What the library offers while there are no VMs.
    @ObservedObject var gallery: GalleryModel

    private var rows: [VMTableRow] {
        LibraryNav.rows(model.vms, group: nav.group ?? .all, search: nav.search, sortOrder: nav.sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            banners
            content
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        let rows = rows
        if model.vms.isEmpty {
            // With no VMs the library is the gallery: the same first screen the creation window opens on.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create your first virtual machine").font(.title2.weight(.semibold))
                    GalleryView(
                        gallery: gallery, status: .none, chooseFile: { newVM(.file($0)) },
                        chooseTile: { newVM(.system($0.entry.kind)) }, act: { _ in })
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        } else if rows.isEmpty, !nav.search.trimmingCharacters(in: .whitespaces).isEmpty {
            empty("magnifyingglass", "No Results", "No virtual machine has “\(nav.search)” in its name.")
        } else if rows.isEmpty {
            empty(
                "play.circle", "Nothing Is Running", "Virtual machines that are running or paused show here.")
        } else {
            table(rows)
        }
    }

    private func table(_ rows: [VMTableRow]) -> some View {
        Table(rows, selection: $nav.selection, sortOrder: $nav.sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Label(row.name, systemImage: SystemGlyph.symbol(for: row.vm))
            }
            .width(min: 120, ideal: 160)
            TableColumn("System", value: \.system).width(min: 90, ideal: 120)
            TableColumn("Status", value: \.statusRank) { row in StatusBadge(status: VMStatus.of(row.vm)) }
                .width(min: 100, ideal: 120)
            TableColumn("Last Used", value: \.lastUsed) { row in
                Text(VMRowLogic.date(row.vm.lastStarted)).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Size on Disk", value: \.sizeOnDisk) { row in
                Text(row.vm.diskUsedBytes.map { $0 == 0 ? "Empty" : VMRowLogic.size($0) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let vm = LibraryNav.selectedVM(ids.first, in: model.vms) {
                ForEach(VMCommand.pageRows, id: \.self) { command in
                    let state = command.state(for: vm)
                    Button(role: command == .delete ? .destructive : nil) {
                        run(command, vm)
                    } label: {
                        Label(state.title, systemImage: state.symbol)
                    }
                    .disabled(!state.enabled)
                }
            } else {
                Button("New Virtual Machine…") { newVM(.gallery) }
            }
        } primaryAction: { ids in
            // Return, or a double click: open its window.
            if let vm = LibraryNav.selectedVM(ids.first, in: model.vms) { run(.open, vm) }
        }
        .onKeyPress(.space) {
            // Space starts or resumes the selected VM, when that is the obvious thing to do.
            guard let vm = LibraryNav.selectedVM(nav.selection, in: model.vms) else { return .ignored }
            let command = VMCommand.primary(for: vm)
            guard command != .open else { return .ignored }
            run(command, vm)
            return .handled
        }
    }

    private func empty(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.secondary).accessibilityHidden(
                true)
            Text(title).font(.title3.weight(.medium))
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder private var banners: some View {
        if let problem = model.hostProblem {
            Banner(text: problem, systemImage: "bolt.horizontal.circle", tint: .red, dismiss: nil)
        }
        if let error = model.lastError {
            Banner(text: error, systemImage: "exclamationmark.triangle", tint: .orange) {
                model.lastError = nil
            }
        }
    }
}

// MARK: detail

/// The pane at the right: the selected VM's preview, status, the commands most wanted, and its facts.
struct VMDetailPane: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var nav: LibraryNav
    @ObservedObject var thumbnails: ThumbnailStore
    @ObservedObject var settings: AppSettingsModel
    let run: (VMCommand, VmSummary) -> Void

    var body: some View {
        if let vm = LibraryNav.selectedVM(nav.selection, in: model.vms) {
            ScrollView { detail(vm).padding(16) }
        } else {
            Text("No Selection").font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(_ vm: VmSummary) -> some View {
        let status = VMStatus.of(vm)
        let primary = VMCommand.primary(for: vm)
        return VStack(alignment: .leading, spacing: 12) {
            preview(vm)
            Text(vm.name).font(.title2.weight(.semibold)).lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                StatusBadge(status: status)
                if let note = status.note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
            HStack {
                button(primary, vm).keyboardShortcut(.defaultAction)
                if primary != .open { button(.open, vm) }
                Spacer()
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(VMRowLogic.details(for: vm), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.value).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            Divider()
            button(.settings, vm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ command: VMCommand, _ vm: VmSummary) -> some View {
        let state = command.state(for: vm)
        return Button {
            run(command, vm)
        } label: {
            Label(state.title, systemImage: state.symbol)
        }
        .disabled(!state.enabled)
    }

    /// The last picture taken of the guest's screen, or a plain tile with the system's glyph: when there
    /// is no picture yet, or previews are turned off in Settings.
    private func preview(_ vm: VmSummary) -> some View {
        let image = settings.showsPreviews ? thumbnails.image(for: vm.uuid) : nil
        return Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .accessibilityLabel("Preview of \(vm.name)’s screen")
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: SystemGlyph.symbol(for: vm)).font(.system(size: 34, weight: .light))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
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
