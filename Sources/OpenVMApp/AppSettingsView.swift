// AppSettingsView — the app's Settings window (openVM ▸ Settings…, Command-comma). A VM's own settings
// are in its Settings window, under Virtual Machine ▸ Settings….
import OpenVMCore
import SwiftUI

struct AppSettingsView: View {
    @ObservedObject var model: AppSettingsModel
    /// The installer cache, when the window has the host to ask.
    var installers: InstallerSettings?

    var body: some View {
        Form {
            Section {
                Toggle("Show openVM in the menu bar", isOn: $model.showsMenuBarIcon)
                Text(
                    "The icon keeps running virtual machines within reach when every window is closed. With it off, openVM stays in the Dock instead."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Show previews of virtual machines in the library", isOn: $model.showsPreviews)
                Text(
                    "A preview is the last picture taken of a virtual machine's screen. Turn this off to keep guest screens out of the library, for example while sharing your screen."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let installers { InstallersSection(vms: installers.vms) }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the Installers part of Settings needs.
struct InstallerSettings {
    let vms: VMListModel
}

/// Where downloaded installers are kept, the space they use, and a way to remove them.
private struct InstallersSection: View {
    @ObservedObject var vms: VMListModel

    var body: some View {
        Section("Installers") {
            LabeledContent("Kept in") {
                Text(OVMPaths.isos.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).textSelection(
                    .enabled)
            }
            LabeledContent("Space used") {
                Text(
                    vms.installers.isEmpty
                        ? "None" : DownloadText.size(vms.installers.reduce(0) { $0 + $1.bytes }))
            }
            ForEach(vms.installers) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(
                            row.complete
                                ? DownloadText.size(row.bytes) : "\(DownloadText.size(row.bytes)) so far"
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { Task { await vms.removeInstaller(entry: row.entry) } }
                }
            }
            Text(
                "openVM keeps a downloaded installer for later virtual machines, and removes one only when you ask. Deleting a virtual machine never removes it."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
