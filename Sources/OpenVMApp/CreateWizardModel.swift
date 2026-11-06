// CreateWizardModel — making a VM without the command line: choose Linux or Windows, get what it
// needs (the Linux files, or the install media built from the person's own ISO), pick a size, and
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
    enum OS: Equatable { case linux, windows }
    enum Page: Equatable { case os, source, resources, account, summary, working, finished, failed(String) }
    enum ISOState: Equatable { case none, checking, usable, problem(String) }
    enum FetchState: Equatable { case idle, running(String), done, failed(String) }
    enum StepState: Equatable { case pending, running, done }

    struct Step: Equatable, Identifiable {
        let id: String
        let title: String
        var state: StepState
    }

    /// Why the run stopped: not a failure, the person asked.
    private struct Cancelled: Error {}

    @Published private(set) var page: Page = .os
    @Published var os: OS = .linux {
        didSet { if os != oldValue { applyDefaults() } }
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

    /// A Linux install needs little, a Windows one a lot: 22 GB for the media while it is built,
    /// and about 20 GB for what is installed.
    static let minDiskGB: [OS: Int] = [.linux: 4, .windows: 40]
    static let freeNeededMB: [OS: UInt64] = [.linux: 4 * 1024, .windows: (22 + 20) * 1024]

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
        let base = os == .windows ? "windows-11" : "linux"
        guard existingNames.contains(base) else { return base }
        var n = 2
        while existingNames.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    private func applyDefaults() {
        cpus = 4
        memoryMB = os == .windows ? 8192 : 4096
        diskGB = os == .windows ? 64 : 32
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
        if name == lastDefaultName { name = defaultName(for: os); lastDefaultName = name }
    }

    func chooseISO(_ path: String) async {
        isoPath = path
        iso = .checking
        do {
            let reply = try await transport.send("windows-iso-check", [("iso", .text(path))])
            if case .bool(true)? = DaemonClient.field(reply, "usable") {
                iso = .usable
            } else if case .text(let problem)? = DaemonClient.field(reply, "problem") {
                iso = .problem(problem)
            } else {
                iso = .problem("openVM could not tell whether this ISO is usable.")
            }
        } catch {
            iso = .problem("\(error)")
        }
    }

    /// Fetches the Linux files, with progress. Windows needs them too when the Mac has no wimlib,
    /// because the helper VM that builds the media is an Alpine guest.
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

    private var haveLinuxFiles: Bool { host?.linuxReady == true || fetch == .done }

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
        case .linux:
            if haveLinuxFiles { return nil }
            return downloadProblem ?? "Download the Linux files to continue."
        case .windows:
            switch iso {
            case .none: return "Choose your Windows 11 ARM64 ISO."
            case .checking: return "Checking the ISO…"
            case .problem(let why): return why
            case .usable: break
            }
            // The media needs wimlib: the Mac's own, or the helper VM's, which is an Alpine guest.
            if host?.hostWimlib != true && !haveLinuxFiles {
                return downloadProblem
                    ?? "Windows setup needs the Linux files on this Mac, because they carry the tool that prepares the installer. Download them to continue."
            }
            return nil
        }
    }

    private var resourcesProblem: String? {
        if let problem = Self.nameProblem(name, existing: existingNames) { return problem }
        if let host {
            if cpus < 1 || cpus > host.maxCpus { return "This Mac allows 1 to \(host.maxCpus) CPUs for a VM." }
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
        case .linux:
            return ["Alpine Linux installs itself on first start, with an XFCE desktop. This takes a few minutes."]
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
        case .os: page = .source
        case .source: page = .resources
        case .resources: page = os == .windows ? .account : .summary
        case .account: page = .summary
        default: break
        }
    }

    func back() {
        switch page {
        case .source: page = .os
        case .resources: page = .source
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
        guard page == .summary else { return }
        cancelled = false
        createdName = nil
        mediaTask = nil
        mediaFinished = false
        progress = ""
        steps =
            (os == .windows ? [Step(id: "media", title: "Prepare the installation media", state: .pending)] : [])
            + [
                Step(id: "create", title: "Create the virtual machine", state: .pending),
                Step(
                    id: "start", title: os == .windows ? "Install Windows (15 to 30 minutes)" : "Install Linux",
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
                throw HostError.remote("Preparing the installation media failed: \(why.isEmpty ? progress : why)")
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
        if os == .windows, let media {
            arguments.append(("boot-mode", .text("windows")))
            arguments.append(("install-media", .text(media)))
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
        reset()
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
        page = .os
        steps = []
        progress = ""
    }

    /// Stops a VM (cancelling its boot if it is booting), waits until it is stopped, and deletes it.
    /// Delete answers "busy" while a cancelled start is still unwinding, so it is retried.
    private func removeVM(_ name: String) async {
        _ = try? await transport.send("stop", [("id", .text(name))])
        for _ in 0..<600 {
            guard let listed = try? await transport.listVMs(), let vm = listed.first(where: { $0.name == name }) else {
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
