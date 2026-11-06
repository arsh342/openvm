// VMSettingsView — one VM's settings. What cannot change right now is shown, not hidden, with
// the reason. It keeps no state of its own (SwiftUI's @State is a macro the Command Line Tools
// cannot build): everything lives in VMSettingsModel.
import AppKit
import OpenVMCore
import SwiftUI

struct VMSettingsView: View {
    @ObservedObject var model: VMSettingsModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.callout).lineLimit(4)
                    Spacer()
                    Button("Dismiss") { model.error = nil }.controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
            Form {
                resources
                timeZone
                sharedFolders
                if model.vm.bootMode == .windows { sound }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if model.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { if await model.apply() { close() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.changes().isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 460)
    }

    private var resources: some View {
        Section("Resources") {
            Picker("CPUs", selection: $model.cpus) {
                ForEach(model.cpuChoices, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Memory", selection: $model.memoryMB) {
                ForEach(model.memoryChoices, id: \.self) { Text(memoryLabel($0)).tag($0) }
            }
            if !model.canEditResources {
                Text("CPUs and memory are read when the VM starts. Shut it down to change them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let problem = model.validationProblem {
                Text(problem).font(.callout).foregroundStyle(.red)
            }
        }
        .disabled(!model.canEditResources)
    }

    private var timeZone: some View {
        Section("Time zone") {
            Picker("Zone", selection: $model.timezone) {
                if model.vm.timezone == nil { Text("Guest default").tag("") }
                ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { Text($0).tag($0) }
            }
            Text("Applied the next time the guest starts or resumes.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var sharedFolders: some View {
        Section("Shared folders") {
            if model.shares.isEmpty {
                Text("No folders are shared with this VM.").foregroundStyle(.secondary)
            }
            ForEach(model.shares) { share in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(share.hostPath).lineLimit(1).truncationMode(.middle)
                        Text("in the guest: \(share.guestPath)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { Task { await model.removeShare(share) } }.controlSize(.small)
                }
            }
            Button("Add Folder…") { chooseFolder() }
            Text("The guest can read and change everything inside a shared folder.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var sound: some View {
        Section("Sound") {
            Text(soundText).foregroundStyle(.secondary)
            if model.soundAvailable {
                if model.soundState == "on" || model.soundState == "pending" {
                    Button("Turn Sound Off…") { Task { await model.disableSound() } }
                } else {
                    Button("Turn Sound On…") { confirmTestMode() }
                }
            } else {
                Text("Start the VM to change its sound.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(model.working)
    }

    private var soundText: String {
        switch model.soundState {
        case "on": return "On, using a test-signed driver. Windows is in Test Mode."
        case "pending": return "Turned on. Restart the guest to finish."
        case "failed": return "Turning sound on failed."
        default: return "Off. Windows has no Microsoft-signed driver for this device."
        }
    }

    // MARK: AppKit prompts

    private func memoryLabel(_ megabytes: Int) -> String {
        megabytes >= 1024 && megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Choose a folder to share with \(model.vm.name)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addShare(hostPath: url.path) }
    }

    /// The consent that gates turning sound on: nothing is sent until the person agrees.
    private func confirmTestMode() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Turn on Windows Test Mode for sound?"
        alert.informativeText = VMSettingsModel.testModeWarning
        alert.addButton(withTitle: "Turn On Test Mode and Sound")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.enableSound(consented: true) }
    }
}
