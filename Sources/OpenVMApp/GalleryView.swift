// GalleryView — where a new VM starts: drop or choose an installer file, or pick a system. It is the
// creation window's first page, and what the library shows while there are no VMs. It keeps no state
// of its own: the tiles and the drop highlight are in GalleryModel, and what happens next is its owner's.
import AppKit
import OpenVMCore
import SwiftUI
import UniformTypeIdentifiers

struct GalleryView: View {
    @ObservedObject var gallery: GalleryModel
    /// What is known about the file that was dropped or chosen.
    let status: GalleryFileStatus
    let chooseFile: (URL) -> Void
    let chooseTile: (GalleryTile) -> Void
    /// Does a failure's one action.
    let act: (FailureMessage.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Install from a file").font(.headline)
                dropArea
                fileStatus
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Or choose a system").font(.headline)
                // Windows first, in full: it is the one with the most to say. The systems openVM downloads
                // itself follow, as short cards side by side.
                ForEach(gallery.tiles.filter { $0.entry.kind == .windows }) { tile in
                    TileView(tile: tile) { chooseTile(tile) }
                }
                let downloads = gallery.tiles.filter { $0.entry.kind == .linux }
                if !downloads.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10
                    ) {
                        ForEach(downloads) { tile in CompactTileView(tile: tile) { chooseTile(tile) } }
                    }
                }
            }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc").font(.system(size: 28, weight: .light)).foregroundStyle(
                .secondary
            )
            .accessibilityHidden(true)
            Text("Drop an installer file here").font(.title3)
            Text("Windows 11 for Arm, or any Linux made for Arm.").font(.callout).foregroundStyle(.secondary)
            Button("Choose File…") { choose() }.padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(gallery.dropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    gallery.dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: gallery.dropTargeted ? [] : [6, 5]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = GalleryModel.installerFile(in: urls) else { return false }
            chooseFile(file)
            return true
        } isTargeted: {
            gallery.dropTargeted = $0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Install from a file. Drop an installer file here, or choose one.")
    }

    @ViewBuilder private var fileStatus: some View {
        switch status {
        case .none: EmptyView()
        case .checking(let name):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking \(name)…").foregroundStyle(.secondary)
            }
        case .usable(let name):
            Label(name, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let failure):
            FailureView(failure: failure, detailsShown: $gallery.detailsShown, act: act)
        }
    }

    /// The open panel starts in Downloads, where a browser leaves an installer.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let iso = UTType(filenameExtension: "iso") { panel.allowedContentTypes = [iso] }
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose an installer file: Windows 11 for Arm, or a Linux made for Arm."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chooseFile(url)
    }
}

/// One system: its name, what it is for, what it costs and its limits, said before anything is downloaded.
private struct TileView: View {
    let tile: GalleryTile
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                SystemLogo(brand: .of(tile.entry)).frame(width: 28, height: 28).frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tile.entry.name).font(.headline)
                        if tile.untested {
                            Text("Not tested yet").font(.caption).padding(.horizontal, 6).padding(
                                .vertical, 1
                            )
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                        }
                    }
                    Text(tile.entry.purpose).font(.callout)
                    Text(tile.cost).font(.callout).foregroundStyle(.secondary)
                    ForEach(tile.entry.limits, id: \.self) { limit in
                        Text(limit).font(.callout).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if let reason = tile.disabledReason {
                        Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(tile.disabledReason != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A system openVM downloads itself, as a short card: its mark, its name, what it is for and what it costs.
/// Its limits are in its tooltip, and are said again on the wizard's summary before anything is created.
private struct CompactTileView: View {
    let tile: GalleryTile
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                SystemLogo(brand: .of(tile.entry)).frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.entry.name).font(.headline).lineLimit(1)
                    Text(tile.entry.purpose).font(.callout).lineLimit(2).fixedSize(
                        horizontal: false, vertical: true)
                    Text(tile.shortCost).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if tile.untested {
                        Text("Not tested yet").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                    if let reason = tile.disabledReason {
                        Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(tile.disabledReason != nil)
        .help(([tile.cost] + tile.entry.limits).joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(tile.entry.limits.joined(separator: " "))
    }
}

/// A failure in plain words: a title, one sentence, one action, and the technical text behind Details.
struct FailureView: View {
    let failure: FailureMessage
    @Binding var detailsShown: Bool
    let act: (FailureMessage.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill").font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(failure.sentence).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let action = failure.action { Button(action.label) { act(action) } }
                if !failure.details.isEmpty {
                    Button(detailsShown ? "Hide Details" : "Details") { detailsShown.toggle() }
                }
            }
            if detailsShown, !failure.details.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        Text(failure.details).font(.callout.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(failure.details, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
