// CreateWizardView — the pages of the creation wizard. It keeps no state of its own; everything is
// in CreateWizardModel, which also decides what each page needs before it lets you on.
import AppKit
import OpenVMCore
import SwiftUI
import UniformTypeIdentifiers

struct CreateWizardView: View {
    @ObservedObject var model: CreateWizardModel
    @ObservedObject var gallery: GalleryModel
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
        case .gallery: galleryPage
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

    /// Where a new VM starts: drop or choose an installer file, or pick a system.
    private var galleryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What do you want to install?").font(.title2.weight(.semibold))
                GalleryView(
                    gallery: gallery, status: fileStatus,
                    chooseFile: { url in Task { await model.useInstaller(url.path) } },
                    chooseTile: { tile in
                        model.chooseSystem(tile.entry.kind == .windows ? .windows : .linuxISO)
                    },
                    act: act)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What the wizard knows about the chosen file, as the gallery shows it.
    private var fileStatus: GalleryFileStatus {
        let name = model.isoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch model.iso {
        case .none: return .none
        case .checking: return .checking(name)
        case .usable: return .usable(name)
        case .problem(let why):
            return .failed(model.isoFailure ?? FailureMessage.of(code: nil, details: why))
        }
    }

    /// Does a failure's one action.
    private func act(_ action: FailureMessage.Action) {
        switch action {
        case .chooseAnotherFile: chooseISO()
        case .getWindows: NSWorkspace.shared.open(InstallerCatalog.windowsPage)
        case .openPage(let url): NSWorkspace.shared.open(url)
        case .downloadAgain, .tryAgain: Task { await model.fetchLinux() }
        }
    }

    /// The installer page: the file the VM installs from. For Windows it is also where the file is
    /// fetched from Microsoft, with what to expect said first.
    private var sourcePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.os == .windows ? "Get Windows 11" : "Your Linux installer").font(
                    .title2.weight(.semibold))
                if model.os == .windows {
                    windowsNotes
                } else {
                    Text(
                        "Choose the installer file of the Linux you want, in its version for Arm (often called ARM64 or aarch64)."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(model.os == .windows ? "Choose the Downloaded File…" : "Choose File…") {
                        chooseISO()
                    }
                    if model.iso == .checking { ProgressView().controlSize(.small) }
                }
                isoStatus
                if model.iso == .usable, model.isoUnchecked {
                    Text(
                        "openVM could not read this file's start-up files, so it cannot say whether it will start. You can still try it."
                    )
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.os == .windows && !(model.host?.hostWimlib ?? false) { helperFiles }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = GalleryModel.installerFile(in: urls) else { return false }
            Task { await model.useInstaller(file.path) }
            return true
        }
    }

    /// What to expect from Windows, before anyone downloads 5 GB and waits half an hour.
    private var windowsNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("openVM does not include Windows. Microsoft gives out the installer on its own page:")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Under “Download Windows 11 Disk Image (ISO) for Arm64”, choose Windows 11.",
                    systemImage: "1.circle")
                Label("Choose your language, and confirm.", systemImage: "2.circle")
                Label(
                    "Press Download Now, then drop the file on this window or choose it below.",
                    systemImage: "3.circle")
            }
            .foregroundStyle(.secondary)
            Button("Get Windows from Microsoft") { NSWorkspace.shared.open(InstallerCatalog.windowsPage) }
            if let windows = InstallerCatalog.entry("windows-11") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        "About \(windows.downloadGB.formatted()) GB to download. Setting Windows up takes 15 to 30 minutes."
                    )
                    ForEach(windows.limits, id: \.self) { Text($0) }
                }
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
        }
    }

    @ViewBuilder private var isoStatus: some View {
        switch model.iso {
        case .none: EmptyView()
        case .checking: Text("Checking the file…").foregroundStyle(.secondary)
        case .usable:
            Label(
                model.isoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .problem(let why):
            FailureView(
                failure: model.isoFailure ?? FailureMessage.of(code: nil, details: why),
                detailsShown: $model.detailsShown,
                act: act)
        }
    }

    @ViewBuilder private var helperFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To prepare the Windows installer, openVM needs a small helper download on this Mac.")
                .foregroundStyle(.secondary)
            if model.host?.linuxReady == true || model.fetch == .done {
                Label("The helper files are ready", systemImage: "checkmark.circle.fill").foregroundStyle(
                    .green)
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
                    Text("About 40 MB. It is used only while the installer is prepared.").font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var resourcesPage: some View {
        Form {
            Section("Name") { TextField("Name", text: $model.name).labelsHidden() }
            Section("Size") {
                Picker("CPUs", selection: $model.cpus) {
                    ForEach(Array(1...min(32, model.host?.maxCpus ?? 8)), id: \.self) {
                        Text("\($0)").tag($0)
                    }
                }
                Picker("Memory", selection: $model.memoryMB) {
                    ForEach(memoryChoices, id: \.self) { Text(memoryLabel($0)).tag($0) }
                }
                Stepper(
                    "Disk: \(model.diskGB) GB", value: $model.diskGB,
                    in: (CreateWizardModel.minDiskGB[model.os] ?? 4)...1024,
                    step: 8)
                Text("The disk grows as the guest uses it; this is only its limit.").font(.callout)
                    .foregroundStyle(.secondary)
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
                    ? "Finish the installer in its window. When it asks to restart, the VM stops, and its window offers Remove Installer and Start."
                    : "It is running, and its window is open."
            )
            .foregroundStyle(.secondary)
        }
    }

    /// A run that failed, in plain words, with what the host said behind Details.
    private func failedPage(_ why: String) -> some View {
        ScrollView {
            FailureView(
                failure: FailureMessage.of(
                    code: model.createdName != nil ? "install-unfinished" : nil, details: why),
                detailsShown: $model.detailsShown, act: act)
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
            case .gallery, .source, .resources, .account, .summary:
                Button("Cancel") {
                    Task {
                        await model.cancel()
                        close()
                    }
                }.keyboardShortcut(.cancelAction)
                if model.page != .gallery { Button("Back") { model.back() } }
                if model.page == .summary {
                    Button("Create") { Task { await model.create() } }.keyboardShortcut(.defaultAction)
                } else if model.page == .gallery && model.iso != .usable {
                    // The gallery moves on by itself when a file or a system is chosen.
                    EmptyView()
                } else {
                    Button("Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.problem != nil)
                }
            case .working:
                if model.cancelling { ProgressView().controlSize(.small) }
                Button(model.cancelling ? "Cancelling…" : "Cancel") {
                    Task {
                        await model.cancel()
                        close()
                    }
                }
                .disabled(model.cancelling)
            case .finished:
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            case .failed:
                if model.createdName != nil {
                    Button("Delete It") {
                        Task {
                            await model.discard()
                            close()
                        }
                    }
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
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose an installer file: Windows 11 for Arm, or a Linux made for Arm."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Whatever page this is, the file says what it is: a Linux file chosen on the Windows page is Linux.
        Task { await model.useInstaller(url.path) }
    }
}
