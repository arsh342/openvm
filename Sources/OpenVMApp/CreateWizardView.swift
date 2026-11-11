// CreateWizardView — the pages of the creation wizard. It keeps no state of its own; everything is
// in CreateWizardModel, which also decides what each page needs before it lets you on.
import AppKit
import OpenVMCore
import SwiftUI
import UniformTypeIdentifiers

struct CreateWizardView: View {
    @ObservedObject var model: CreateWizardModel
    /// Closes the window.
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 520, minHeight: 500)
    }

    @ViewBuilder private var content: some View {
        switch model.page {
        case .os: osPage
        case .source: sourcePage
        case .resources: resourcesPage
        case .account: accountPage
        case .summary: summaryPage
        case .working: workingPage
        case .finished: finishedPage
        case .failed(let why): failedPage(why)
        }
    }

    // MARK: pages

    private var osPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What do you want to run?").font(.title2.weight(.semibold))
            choice(
                .linuxISO, symbol: "opticaldisc", title: "Linux, from an ISO",
                detail: "Ubuntu, Fedora, Debian, Kali, Omarchy or any other ARM64 build. You finish its own installer in the VM's window.")
            choice(
                .windows, symbol: "macwindow", title: "Windows 11",
                detail: "The ARM64 edition, installed from your own ISO from Microsoft. Setup takes about 15 to 30 minutes.")
        }
    }

    private func choice(_ os: CreateWizardModel.OS, symbol: String, title: String, detail: String) -> some View {
        Button {
            model.os = os
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 28)).frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.os == os { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(model.os == os ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(model.os == os ? Color.accentColor : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var sourcePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.os == .windows ? "Your Windows ISO" : "Your Linux ISO")
                .font(.title2.weight(.semibold))
            if model.os == .linuxISO {
                Text("Download the ARM64 (aarch64) ISO of the distribution you want, and choose it here. Macs with Apple silicon cannot run Intel and AMD (x86_64) builds.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose ISO…") { chooseISO() }
                    if model.iso == .checking { ProgressView().controlSize(.small) }
                }
                isoStatus
                if model.iso == .usable, model.isoUnchecked {
                    Text("openVM could not read this ISO's boot files, so it cannot say whether it will start. You can still try it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.os == .windows {
                Text("openVM ships no Windows. Download Windows 11 (ARM64) from Microsoft and choose the ISO here.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Choose ISO…") { chooseISO() }
                    if model.iso == .checking { ProgressView().controlSize(.small) }
                }
                isoStatus
            }
            if model.os == .windows && !(model.host?.hostWimlib ?? false) {
                helperFiles
            }
        }
    }

    @ViewBuilder private var isoStatus: some View {
        switch model.iso {
        case .none: EmptyView()
        case .checking: Text("Checking the ISO…").foregroundStyle(.secondary)
        case .usable:
            Label(model.isoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .problem(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var helperFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This Mac has no wimlib, so a short-lived helper VM prepares the installer. It needs a small download.")
                .foregroundStyle(.secondary)
            if model.host?.linuxReady == true || model.fetch == .done {
                Label("The helper files are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                switch model.fetch {
                case .running(let line):
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await model.fetchLinux() } }
                case .idle, .done:
                    Button("Download Helper Files") { Task { await model.fetchLinux() } }
                    Text("About 40 MB: a small Linux system from Alpine's mirror, used only to build the installer.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resourcesPage: some View {
        Form {
            Section("Name") { TextField("Name", text: $model.name).labelsHidden() }
            Section("Size") {
                Picker("CPUs", selection: $model.cpus) {
                    ForEach(Array(1...min(32, model.host?.maxCpus ?? 8)), id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Memory", selection: $model.memoryMB) {
                    ForEach(memoryChoices, id: \.self) { Text(memoryLabel($0)).tag($0) }
                }
                Stepper(
                    "Disk: \(model.diskGB) GB", value: $model.diskGB, in: (CreateWizardModel.minDiskGB[model.os] ?? 4)...1024,
                    step: 8)
                Text("The disk grows as the guest uses it; this is only its limit.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var memoryChoices: [Int] {
        let steps = [2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768]
        let limit = model.host?.maxMemoryMB ?? Int.max
        return Set(steps.filter { $0 <= limit } + [model.memoryMB]).sorted()
    }

    private func memoryLabel(_ megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    private var accountPage: some View {
        Form {
            Section("Your Windows account") {
                TextField("User name", text: $model.accountName)
                SecureField("Password", text: $model.accountPassword)
                SecureField("Confirm password", text: $model.accountConfirm)
                Text("This is an administrator account inside the guest. It is separate from your Mac's.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Signing in") {
                Toggle("Sign in automatically when Windows starts", isOn: $model.autoLogon)
                Text(
                    model.autoLogon
                        ? "Clipboard, file drops and resizing work from the start. Your password is kept inside the guest to do this, in a form that can be read."
                        : "Windows asks for your password at every start. Clipboard, file drops and resizing wait until you sign in."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var systemLabel: String {
        switch model.os {
        case .windows: return "Windows 11 (ARM64)"
        case .linuxISO: return model.isoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Linux"
        }
    }

    private var summaryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready to create").font(.title2.weight(.semibold))
            row("Name", model.name)
            row("System", systemLabel)
            row("CPUs", "\(model.cpus)")
            row("Memory", memoryLabel(model.memoryMB))
            row("Disk", "\(model.diskGB) GB")
            if model.os == .windows { row("Account", model.accountName) }
            Divider()
            ForEach(model.summaryNotes, id: \.self) { note in
                Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
        }
    }

    private var workingPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Creating \(model.name)").font(.title2.weight(.semibold))
            ForEach(model.steps) { step in
                HStack(spacing: 10) {
                    switch step.state {
                    case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
                    case .running: ProgressView().controlSize(.small)
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(step.title).foregroundStyle(step.state == .pending ? .secondary : .primary)
                }
            }
            if !model.progress.isEmpty {
                Text(model.progress).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text("Cancelling removes everything created so far.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var finishedPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text(model.os == .linuxISO ? "\(model.name) is starting its installer" : "\(model.name) is ready")
                .font(.title2.weight(.semibold))
            Text(
                model.os == .linuxISO
                    ? "Finish the installer in its window. When it asks to restart, the VM stops: press Start."
                    : "It is running, and its window is open."
            )
            .foregroundStyle(.secondary)
        }
    }

    private func failedPage(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.orange)
            Text("Something went wrong").font(.title2.weight(.semibold))
            ScrollView {
                Text(why).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.createdName != nil {
                Text("The virtual machine was created and is still there. You can look at it, or delete it and start again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: buttons

    /// What blocks Continue, unless the page is already showing it: an ISO problem and a failed or
    /// running download are written out in the page, and saying them twice is noise.
    private var footerProblem: String? {
        guard let problem = model.problem else { return nil }
        if model.page == .source {
            if case .problem = model.iso { return nil }
            switch model.fetch {
            case .failed, .running: return nil
            case .idle, .done: break
            }
        }
        return problem
    }

    private var footer: some View {
        HStack {
            if let problem = footerProblem {
                Text(problem).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            switch model.page {
            case .os, .source, .resources, .account, .summary:
                Button("Cancel") { Task { await model.cancel(); close() } }.keyboardShortcut(.cancelAction)
                if model.page != .os { Button("Back") { model.back() } }
                if model.page == .summary {
                    Button("Create") { Task { await model.create() } }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.problem != nil)
                }
            case .working:
                if model.cancelling { ProgressView().controlSize(.small) }
                Button(model.cancelling ? "Cancelling…" : "Cancel") { Task { await model.cancel(); close() } }
                    .disabled(model.cancelling)
            case .finished:
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            case .failed:
                if model.createdName != nil {
                    Button("Delete It") { Task { await model.discard(); close() } }
                }
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let iso = UTType(filenameExtension: "iso") { panel.allowedContentTypes = [iso] }
        panel.message = model.os == .linuxISO ? "Choose an ARM64 Linux ISO." : "Choose the Windows 11 ARM64 ISO."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseISO(url.path) }
    }
}
