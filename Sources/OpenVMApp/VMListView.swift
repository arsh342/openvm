// VMListView — the "All Virtual Machines" page: a card for every VM, with a picture of its screen, its
// state, and the action you most likely want. The state of each VM comes from the host, so a change made
// with openvmctl shows up here.
import OpenVMCore
import SwiftUI

struct VMListView: View {
    @ObservedObject var model: VMListModel
    @ObservedObject var thumbnails: ThumbnailStore
    /// Opens a VM's window.
    let open: (VmSummary) -> Void
    /// Opens a VM's settings.
    let settings: (VmSummary) -> Void
    /// Starts the creation wizard.
    let newVM: () -> Void

    init(
        model: VMListModel, thumbnails: ThumbnailStore = .shared, open: @escaping (VmSummary) -> Void,
        settings: @escaping (VmSummary) -> Void, newVM: @escaping () -> Void
    ) {
        self.model = model
        self.thumbnails = thumbnails
        self.open = open
        self.settings = settings
        self.newVM = newVM
    }

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 20, alignment: .top)]

    var body: some View {
        Group {
            if model.vms.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(model.vms) { vm in
                            VMCard(vm: vm, image: thumbnails.image(for: vm.uuid)) { perform($0, on: vm) }
                        }
                        NewVMCard(action: newVM)
                    }
                    .padding(.horizontal, 24).padding(.top, 44).padding(.bottom, 24)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No virtual machines").font(.title3.weight(.medium))
            Text("Create one to get started.").foregroundStyle(.secondary)
            Button("New VM…", action: newVM).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    /// The card's actions go to the library's owner, which knows how to start, pause or delete.
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

private struct VMCard: View {
    let vm: VmSummary
    let image: NSImage?
    let perform: (VMAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            screen
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
                .overlay(alignment: .bottomTrailing) { playButton.padding(10) }
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            HStack(spacing: 6) {
                if vm.activity != nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dot).frame(width: 8, height: 8)
                }
                Text(vm.name).font(.headline).lineLimit(1)
            }
            Text(VMRowLogic.statusText(for: vm) + " · " + VMRowLogic.subtitle(for: vm))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture { perform(.open) }
        .contextMenu {
            ForEach(VMRowLogic.actions(for: vm), id: \.self) { action in
                Button(role: action == .delete ? .destructive : nil) { perform(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
    }

    /// The last picture taken of the guest's screen, or a plain tile with the system's symbol.
    @ViewBuilder private var screen: some View {
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
                    .font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    /// The one thing most wanted from a card: start it, resume it, or open it.
    private var playButton: some View {
        let action = VMRowLogic.primaryAction(for: vm)
        return Button { perform(action) } label: {
            Image(systemName: action == .open ? "macwindow" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
        .help(action.title)
    }

    private var dot: Color {
        switch vm.state {
        case .running: return .green
        case .suspended: return .orange
        case .stopped, .starting, .stopping: return .gray
        }
    }
}

private struct NewVMCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Colour.clear takes the whole width offered, so the tile is as big as a VM card.
            Color.clear
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 30, weight: .light))
                        Text("New VM…").font(.headline)
                    }
                    .foregroundStyle(.secondary))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
