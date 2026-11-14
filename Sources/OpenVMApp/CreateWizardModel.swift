// CreateWizardModel — making a VM without the command line: choose Linux or Windows, get what it
// needs (an ISO, or the install media built from the person's own ISO), pick a size, and
// start it. Everything it does is something `openvmctl` can do; what it adds is the order, the
// checks before each step, and the cleanup when a run is cancelled or fails.
//
// Nothing is created until the last page. Cancelling a run removes what it made: the media build
// is cancelled (the host deletes the half-written image), and a VM already created is stopped and
// deleted (the host deletes the install media with it). A run that fails after the VM exists keeps
// it, so it can be looked at or started again.
import Combine
import Foundation
import OpenVMCore

@MainActor
final class CreateWizardModel: ObservableObject {
    enum OS: Equatable { case windows, linuxISO }
    enum Page: Equatable {
        case gallery, source, resources, account, summary, working, finished
        case failed(String)
    }
    enum ISOState: Equatable {
        case none, checking, usable
        case problem(String)
    }
    enum FetchState: Equatable {
        case idle
        case running(String)
        case done
        case failed(String)
    }
    enum StepState: Equatable { case pending, running, done }

    struct Step: Equatable, Identifiable {
        let id: String
        let title: String
        var state: StepState
    }

    /// A download the wizard started, or joined: the host runs it, and it outlives this window.
    struct Download: Equatable {
        enum State: Equatable {
            case running, paused, verified
            case failed(FailureMessage)
        }
        let entry: InstallerCatalog.Entry
        var taskId: String?
        var state: State = .running
        var done: UInt64 = 0
        var total: UInt64?
        var bytesPerSecond: UInt64 = 0
    }

    /// Why the run stopped: not a failure, the person asked.
    private struct Cancelled: Error {}

    @Published private(set) var page: Page = .gallery
    @Published var os: OS = .linuxISO {
        didSet {
            guard os != oldValue else { return }
            applyDefaults()
            // An ISO checked for one system says nothing about the other.
            isoPath = nil
            iso = .none
            isoUnchecked = false
            isoFailure = nil
            download = nil
        }
    }
    @Published var name = ""
    @Published var cpus = 4
    @Published var memoryMB = 4096
    @Published var diskGB = 32
    /// The Windows account. The password stays here, in memory, until the install media has it.
    @Published var accountName = ""
    @Published var accountPassword = ""
    @Published var accountConfirm = ""
    @Published var autoLogon = true
    @Published private(set) var isoPath: String?
    @Published private(set) var iso: ISOState = .none
    /// The ISO's boot files could not be read, so it may or may not start. It is still offered.
    @Published private(set) var isoUnchecked = false
    /// Why the chosen file cannot be used, in plain words (the gallery and the installer page show it).
    @Published private(set) var isoFailure: FailureMessage?
    /// The technical text of a failure is on show.
    @Published var detailsShown = false
    /// The installer this VM is waiting for, when it was chosen from a download tile.
    @Published private(set) var download: Download?
    @Published private(set) var fetch: FetchState = .idle
    @Published private(set) var host: HostInfo?
    @Published private(set) var steps: [Step] = []
    /// The last line of whatever long job is running (a download, a media build).
    @Published private(set) var progress = ""
    /// The VM this wizard made, while it exists.
    @Published private(set) var createdName: String?
    /// Cancelling takes seconds (a media build unmounts and deletes a 22 GB image), and the wizard is
    /// not done until it has finished.
    @Published private(set) var cancelling = false

    private let transport: any HostTransport
    private let pollInterval: Duration
    private let cancelWait: Duration
    private let openWindow: (String) -> Void
    private var existingNames: Set<String>
    private var lastDefaultName = ""
    private var cancelled = false
    private var mediaTask: String?
    private var mediaFinished = false

    init(
        transport: any HostTransport, existingNames: [String], pollInterval: Duration = .seconds(1),
        cancelWait: Duration = .seconds(60), openWindow: @escaping (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.existingNames = Set(existingNames)
        self.pollInterval = pollInterval
        self.cancelWait = cancelWait
        self.openWindow = openWindow
        applyDefaults()
        accountName = Self.suggestedAccountName(NSUserName())
    }

    // MARK: sizes and names

    /// A Windows install needs a lot: 22 GB for the media while it is built,
    /// and about 20 GB for what is installed.
    static let minDiskGB: [OS: Int] = [.windows: 40, .linuxISO: 16]
    static let freeNeededMB: [OS: UInt64] = [.windows: (22 + 20) * 1024, .linuxISO: 16 * 1024]

    static func nameProblem(_ name: String, existing: Set<String>) -> String? {
        if name.isEmpty { return "Give the VM a name." }
        guard VmRegistry.validName(name) else {
            return "Use 1 to 64 letters, digits, _ or -, starting with a letter or digit."
        }
        if existing.contains(name) { return "A VM called \(name) already exists." }
        return nil
    }

    static func diskProblem(os: OS, freeDiskMB: UInt64) -> String? {
        let needed = freeNeededMB[os] ?? 0
        guard freeDiskMB < needed else { return nil }
        let what =
            os == .windows
            ? "Windows setup needs about \(needed / 1024) GB free: 22 GB for the installation media while it is built, and about 20 GB for Windows."
            : "Linux setup needs about \(needed / 1024) GB free."
        return "\(what) This Mac has \(freeDiskMB / 1024) GB free."
    }

    private func defaultName(for os: OS) -> String {
        let base = os == .windows ? "windows-11" : "linux-vm"
        guard existingNames.contains(base) else { return base }
        var n = 2
        while existingNames.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func applyDefaults() {
        cpus = 4
        memoryMB = os == .windows ? 8192 : 4096
        diskGB = 64
        // A name the person typed is theirs; only the one this wizard suggested is replaced.
        if name.isEmpty || name == lastDefaultName {
            name = defaultName(for: os)
            lastDefaultName = name
        }
    }

    // MARK: loading and the source page

    func load() async {
        host = try? await transport.hostInfo()
        if let listed = try? await transport.listVMs() { existingNames.formUnion(listed.map(\.name)) }
        if name == lastDefaultName {
            name = defaultName(for: os)
            lastDefaultName = name
        }
    }

    /// Checks a file chosen on the installer page, as the system already chosen.
    func chooseISO(_ path: String) async {
        isoPath = path
        iso = .checking
        isoFailure = nil
        do {
            let op = os == .linuxISO ? "linux-iso-check" : "windows-iso-check"
            take(try await transport.send(op, [("iso", .text(path))]))
        } catch {
            refuse(code: nil, "\(error)")
        }
    }

    /// Takes a file dropped or chosen in the gallery: the host says whether it is Windows or Linux, and
    /// a usable one moves the wizard on. This is what makes the gallery one step instead of two.
    func useInstaller(_ path: String) async {
        download = nil  // a file of the person's own replaces a download; the host keeps the download
        isoPath = path
        iso = .checking
        isoFailure = nil
        do {
            let reply = try await transport.send("installer-identify", [("iso", .text(path))])
            if text(reply, "kind") == "windows" { setSystem(.windows, keeping: path) }
            if text(reply, "kind") == "linux" { setSystem(.linuxISO, keeping: path) }
            take(reply)
            if iso == .usable, page == .gallery || page == .source { page = afterInstaller }
        } catch {
            refuse(code: nil, "\(error)")
        }
    }

    /// What a VM made from this file runs. An installer openVM downloaded is named `<catalog id>-<file>` in its
    /// cache, so it is said by its catalog name ("Kali Linux"); any other file by its own name, without ".iso".
    nonisolated static func systemName(forFile path: String) -> String {
        let file = URL(fileURLWithPath: path)
        if file.deletingLastPathComponent().standardizedFileURL.path
            == OVMPaths.isos.standardizedFileURL.path,
            let entry = InstallerCatalog.entries.first(where: {
                file.lastPathComponent.hasPrefix($0.id + "-")
            })
        {
            return entry.name
        }
        return file.deletingPathExtension().lastPathComponent
    }

    /// A tile was chosen, in any gallery. This is the one way in for a tile: Windows opens its page, where
    /// its file is brought in, and a system openVM downloads itself starts downloading.
    func choose(_ entry: InstallerCatalog.Entry) async {
        if entry.kind == .windows {
            chooseSystem(.windows)
        } else {
            await chooseDownload(entry)
        }
    }

    /// A download tile was chosen. The host starts the download, and the wizard goes on to the sizes
    /// while it runs: only Create waits for the file to be verified.
    func chooseDownload(_ entry: InstallerCatalog.Entry) async {
        os = .linuxISO
        isoPath = nil
        iso = .none
        isoFailure = nil
        download = Download(entry: entry)
        page = .resources
        await startDownload()
    }

    /// Starts the download, or picks it up, and follows it until it stops.
    func startDownload() async {
        guard var current = download else { return }
        do {
            let started = try await transport.send(
                "task-start", [("kind", .text("fetch-iso")), ("entry", .text(current.entry.id))])
            guard case .text(let id)? = DaemonClient.field(started, "taskId") else {
                throw HostError.remote("The host did not start the download.")
            }
            current.taskId = id
            current.state = .running
            download = current
            while let now = download, now.taskId == id, now.state == .running {
                let status = try await transport.send("task-status", [("taskId", .text(id))])
                guard var fresh = download, fresh.taskId == id else { return }
                if case .uint(let done)? = DaemonClient.field(status, "bytesDone") { fresh.done = done }
                if case .uint(let total)? = DaemonClient.field(status, "bytesTotal") { fresh.total = total }
                if case .uint(let speed)? = DaemonClient.field(status, "bytesPerSecond") {
                    fresh.bytesPerSecond = speed
                }
                switch text(status, "state") {
                case "done":
                    fresh.state = .verified
                    isoPath = text(status, "path")
                    iso = .usable
                case "failed":
                    let code = text(status, "code")
                    fresh.state = .failed(
                        FailureMessage.of(
                            code: code.isEmpty ? "download-failed" : code, details: text(status, "error"),
                            page: fresh.entry.page))
                case "cancelled": fresh.state = .paused
                default: break
                }
                download = fresh
                if fresh.state == .running { try await Task.sleep(for: pollInterval) }
            }
        } catch {
            guard var failed = download else { return }
            failed.state = .failed(
                FailureMessage.of(code: "download-failed", details: "\(error)", page: failed.entry.page))
            download = failed
        }
    }

    /// Stops the download. The host keeps what it has, so it can be picked up again.
    func pauseDownload() async {
        guard let id = download?.taskId, download?.state == .running else { return }
        _ = try? await transport.send("task-cancel", [("taskId", .text(id))])
        if download?.taskId == id { download?.state = .paused }
    }

    /// Why Create must wait, or nil: the installer is still downloading, or its download stopped.
    var createBlocked: String? {
        guard let download else { return nil }
        switch download.state {
        case .verified: return nil
        case .running: return "Waiting for \(download.entry.name) to finish downloading."
        case .paused: return "The download of \(download.entry.name) is paused."
        case .failed: return "\(download.entry.name) did not download."
        }
    }

    /// A tile was chosen: the installer page is next, where its file is brought in.
    func chooseSystem(_ system: OS) {
        download = nil
        os = system
        page = .source
    }

    /// Changing the system forgets the file (it was checked as the other system), so it is put back.
    private func setSystem(_ system: OS, keeping path: String) {
        os = system
        isoPath = path
        iso = .checking
    }

    private func take(_ reply: [(key: String, value: CBOR)]) {
        if case .bool(true)? = DaemonClient.field(reply, "usable") {
            iso = .usable
            isoUnchecked = DaemonClient.field(reply, "unknown") == .bool(true)
        } else if case .text(let problem)? = DaemonClient.field(reply, "problem") {
            let code = text(reply, "code")
            refuse(code: code.isEmpty ? nil : code, problem)
        } else {
            refuse(code: nil, "openVM could not tell whether this file is usable.")
        }
    }

    private func refuse(code: String?, _ problem: String) {
        iso = .problem(problem)
        detailsShown = false
        isoFailure = FailureMessage.of(code: code, details: problem)
    }

    /// Where a usable file leads: straight to the sizes, unless Windows still needs its helper download.
    private var afterInstaller: Page { sourceProblem == nil ? .resources : .source }

    /// What the VM runs, for the library: "Windows 11", or the Linux file's name without ".iso".
    var systemName: String {
        if os == .windows { return "Windows 11" }
        if let download { return download.entry.name }
        guard let isoPath else { return "Linux" }
        return Self.systemName(forFile: isoPath)
    }

    /// Fetches the helper VM's files, with progress. Windows needs them when the Mac has no wimlib,
    /// because the helper VM builds the media then.
    func fetchLinux() async {
        if case .running = fetch { return }
        fetch = .running("Starting…")
        do {
            let started = try await transport.send("task-start", [("kind", .text("fetch-linux"))])
            guard case .text(let id)? = DaemonClient.field(started, "taskId") else {
                fetch = .failed("The host did not start the download.")
                return
            }
            while true {
                let status = try await transport.send("task-status", [("taskId", .text(id))])
                let line = text(status, "progress")
                switch text(status, "state") {
                case "done":
                    host = (try? await transport.hostInfo()) ?? host
                    fetch = .done
                    return
                case "failed":
                    let why = text(status, "error")
                    fetch = .failed(why.isEmpty ? line : why)
                    return
                case "cancelled":
                    fetch = .failed("The download was cancelled.")
                    return
                default:
                    fetch = .running(line.isEmpty ? "Downloading…" : line)
                }
                try await Task.sleep(for: pollInterval)
            }
        } catch {
            fetch = .failed("\(error)")
        }
    }

    private func text(_ fields: [(key: String, value: CBOR)], _ key: String) -> String {
        if case .text(let value)? = DaemonClient.field(fields, key) { return value }
        return ""
    }

    // MARK: what each page needs

    /// The helper VM's files: it builds the Windows installer when the Mac has no wimlib.
    private var haveHelperFiles: Bool { host?.linuxReady == true || fetch == .done }

    /// Why Next is blocked on this page, or nil when it is not.
    var problem: String? {
        switch page {
        case .source: return sourceProblem
        case .resources: return resourcesProblem
        case .account:
            return WindowsAccount.nameProblem(accountName)
                ?? WindowsAccount.passwordProblem(accountPassword, confirm: accountConfirm)
        default: return nil
        }
    }

    private var downloadProblem: String? {
        switch fetch {
        case .running(let line): return line
        case .failed(let why): return why
        case .idle, .done: return nil
        }
    }

    private var sourceProblem: String? {
        switch os {
        case .linuxISO:
            switch iso {
            case .none: return "Choose a Linux installer file."
            case .checking: return "Checking the file…"
            case .problem(let why): return why
            case .usable: return nil
            }
        case .windows:
            switch iso {
            case .none: return "Choose the Windows 11 file you downloaded."
            case .checking: return "Checking the file…"
            case .problem(let why): return why
            case .usable: break
            }
            // The media needs wimlib: the Mac's own, or the helper VM's.
            if host?.hostWimlib != true && !haveHelperFiles {
                return downloadProblem
                    ?? "Windows setup needs a small helper download on this Mac, because it carries the tool that prepares the installer. Download it to continue."
            }
            return nil
        }
    }

    private var resourcesProblem: String? {
        if let problem = Self.nameProblem(name, existing: existingNames) { return problem }
        if let host {
            if cpus < 1 || cpus > host.maxCpus {
                return "This Mac allows 1 to \(host.maxCpus) CPUs for a VM."
            }
            if memoryMB < 1024 || memoryMB > host.maxMemoryMB {
                return "This Mac allows 1024 to \(host.maxMemoryMB) MB of memory for a VM."
            }
        }
        let minimum = Self.minDiskGB[os] ?? 4
        if diskGB < minimum || diskGB > 1024 {
            return "\(os == .windows ? "Windows" : "Linux") needs a disk of \(minimum) to 1024 GB."
        }
        if let host, let problem = Self.diskProblem(os: os, freeDiskMB: host.freeDiskMB) { return problem }
        return nil
    }

    var summaryNotes: [String] {
        switch os {
        case .windows:
            return [
                autoLogon
                    ? "Windows will sign in to the administrator account \(accountName) by itself at every start. Your password is kept inside the guest to do that."
                    : "Windows will ask for the password of the administrator account \(accountName) at every start. Clipboard, file drops and resizing wait until you sign in.",
                "Setup takes about 15 to 30 minutes. You can watch it in the VM's window.",
            ]
        case .linuxISO:
            return [
                "The VM starts from your ISO, and you finish the distribution's own installer in its window.",
                "When the installer asks to restart, the VM stops. Its window then offers Remove Installer and Start.",
                "Clipboard, file drops and Send to Mac need openVM's guest tools, which these guests do not have yet.",
                "If the guest makes no sound, its PipeWire needs a setting for larger buffers: see \"If the guest makes no sound\" in openVM's README.",
            ]
        }
    }

    /// The Mac's short name when Windows would take it, because it is what most people would type.
    static func suggestedAccountName(_ macName: String) -> String {
        WindowsAccount.nameProblem(macName) == nil ? macName : "user"
    }

    // MARK: moving between pages

    func next() {
        guard problem == nil else { return }
        switch page {
        case .gallery: page = iso == .usable ? afterInstaller : .source
        case .source: page = .resources
        case .resources: page = os == .windows ? .account : .summary
        case .account: page = .summary
        default: break
        }
    }

    func back() {
        switch page {
        case .source: page = .gallery
        // A downloaded installer has no file page: the gallery is where it was chosen.
        case .resources: page = download == nil ? .source : .gallery
        case .account: page = .resources
        case .summary: page = os == .windows ? .account : .resources
        default: break
        }
    }

    // MARK: the run

    private func check() throws { if cancelled { throw Cancelled() } }

    private func mark(_ id: String, _ state: StepState) {
        if let index = steps.firstIndex(where: { $0.id == id }) { steps[index].state = state }
    }

    /// Does everything the pages asked for. Stops, quietly, if cancelled; says why if it fails.
    func create() async {
        guard page == .summary, createBlocked == nil else { return }
        cancelled = false
        createdName = nil
        mediaTask = nil
        mediaFinished = false
        progress = ""
        steps =
            (os == .windows
                ? [Step(id: "media", title: "Prepare the installation media", state: .pending)] : [])
            + [
                Step(id: "create", title: "Create the virtual machine", state: .pending),
                Step(
                    id: "start",
                    title: os == .windows
                        ? "Install Windows (15 to 30 minutes)"
                        : (os == .linuxISO ? "Start the installer" : "Install Linux"),
                    state: .pending),
            ]
        page = .working
        do {
            var media: String?
            if os == .windows { media = try await buildMedia() }
            try check()
            try await createVM(media: media)
            try check()
            mark("start", .running)
            openWindow(name)  // so the install can be watched while it runs
            _ = try await transport.send("start", [("id", .text(name))])
            try check()
            mark("start", .done)
            page = .finished
        } catch is Cancelled {
            // cancel() is cleaning up and resets the page
        } catch {
            if cancelled { return }
            page = .failed("\(error)")
        }
    }

    private func buildMedia() async throws -> String {
        mark("media", .running)
        guard let isoPath else { throw HostError.remote("No ISO was chosen.") }
        let started = try await transport.send(
            "task-start",
            [
                ("kind", .text("windows-media")), ("iso", .text(isoPath)), ("name", .text(name)),
                ("user", .text(accountName)), ("password", .text(accountPassword)),
                ("autologon", .text(autoLogon ? "yes" : "no")),
            ])
        // The media has it now. Nothing else in the app needs the password.
        accountPassword = ""
        accountConfirm = ""
        guard case .text(let id)? = DaemonClient.field(started, "taskId"),
            case .text(let output)? = DaemonClient.field(started, "output")
        else { throw HostError.remote("The host did not start building the installation media.") }
        mediaTask = id
        while true {
            try check()
            let status = try await transport.send("task-status", [("taskId", .text(id))])
            progress = text(status, "progress")
            switch text(status, "state") {
            case "done":
                mediaFinished = true
                mark("media", .done)
                return output
            case "failed":
                mediaFinished = true
                let why = text(status, "error")
                throw HostError.remote(
                    "Preparing the installation media failed: \(why.isEmpty ? progress : why)")
            case "cancelled":
                mediaFinished = true
                throw Cancelled()
            default: break
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func createVM(media: String?) async throws {
        mark("create", .running)
        var arguments: [(key: String, value: CBOR)] = [
            ("name", .text(name)), ("cpus", .uint(UInt64(cpus))), ("memoryMB", .uint(UInt64(memoryMB))),
            ("diskSizeMB", .uint(UInt64(diskGB) * 1024)),
        ]
        if VmRegistry.validSystemName(systemName) { arguments.append(("system-name", .text(systemName))) }
        if os == .windows, let media {
            arguments.append(("boot-mode", .text("windows")))
            arguments.append(("install-media", .text(media)))
        }
        if os == .linuxISO, let isoPath {
            arguments.append(("boot-mode", .text("linux-iso")))
            arguments.append(("install-media", .text(isoPath)))
        }
        _ = try await transport.send("create", arguments)
        createdName = name
        mark("create", .done)
    }

    // MARK: cancelling and cleaning up

    /// Stops what is running and removes what it made. From any page it ends with the wizard reset.
    func cancel() async {
        if page == .working {
            cancelling = true
            defer { cancelling = false }
            cancelled = true
            if let id = mediaTask, !mediaFinished {
                _ = try? await transport.send("task-cancel", [("taskId", .text(id))])
                await waitForTaskToStop(id)
            }
            if let name = createdName { await removeVM(name) }
        }
        await stopDownload()
        reset()
    }

    /// Stops the installer download this wizard started, when the wizard is cancelled or closed. The host
    /// keeps what it has, so choosing the same system again picks up where it stopped.
    func stopDownload() async {
        if download?.state == .running { await pauseDownload() }
        download = nil
    }

    /// Returns once the task is no longer running, so its cleanup is finished: the script unmounts
    /// the ISO and the image and the host deletes the half-written file. Bounded, so a task that
    /// will not stop does not hold the wizard.
    private func waitForTaskToStop(_ id: String) async {
        let deadline = ContinuousClock.now + cancelWait
        while ContinuousClock.now < deadline {
            guard let status = try? await transport.send("task-status", [("taskId", .text(id))]),
                text(status, "state") == "running"
            else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Removes the VM a failed run left behind, when the person would rather start again.
    func discard() async {
        if let name = createdName { await removeVM(name) }
        reset()
    }

    private func reset() {
        page = .gallery
        steps = []
        progress = ""
    }

    /// Stops a VM (cancelling its boot if it is booting), waits until it is stopped, and deletes it.
    /// Delete answers "busy" while a cancelled start is still unwinding, so it is retried.
    private func removeVM(_ name: String) async {
        _ = try? await transport.send("stop", [("id", .text(name))])
        for _ in 0..<600 {
            guard let listed = try? await transport.listVMs(),
                let vm = listed.first(where: { $0.name == name })
            else {
                break
            }
            if vm.state == .stopped && vm.activity == nil { break }
            try? await Task.sleep(for: pollInterval)
        }
        for _ in 0..<600 {
            do {
                _ = try await transport.send("delete", [("id", .text(name))])
                createdName = nil
                return
            } catch {
                guard "\(error)".contains("busy") else {
                    FileHandle.standardError.write(Data("openvm: could not remove \(name): \(error)\n".utf8))
                    return
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }
}
