// VMSettingsModel — what a person can change about one VM, and what is allowed when.
//
// CPUs and memory are read when the VM boots, so only a stopped VM can change them. The time
// zone, shared folders and sound can change while it runs. Every choice offered is one the host
// will accept: the limits come from what this Mac can give a VM.
import Combine
import Foundation
import OpenVMCore

@MainActor
final class VMSettingsModel: ObservableObject {
    struct Share: Equatable, Identifiable {
        let hostPath: String
        let guestPath: String
        var id: String { hostPath }
    }

    @Published var cpus: Int
    @Published var memoryMB: Int
    /// An IANA zone name, or "" for the guest's own.
    @Published var timezone: String
    @Published private(set) var vm: VmSummary
    @Published private(set) var host: HostInfo?
    @Published private(set) var shares: [Share] = []
    /// The guest's sound switch: off, pending, on or failed. Nil when unknown.
    @Published private(set) var soundState: String?
    @Published var error: String?
    /// A slow request is running (turning sound on takes up to two minutes).
    @Published private(set) var working = false

    private let transport: any HostTransport

    init(vm: VmSummary, transport: any HostTransport) {
        self.vm = vm
        self.transport = transport
        self.cpus = vm.cpus
        self.memoryMB = vm.memoryMB
        self.timezone = vm.timezone ?? ""
    }

    /// What turning on Windows sound costs. Shown, and agreed to, before it is sent.
    static let testModeWarning =
        "Windows has no sound driver signed by Microsoft for Apple's virtual sound device, so sound uses a "
        + "third-party driver that is only test-signed. Turning it on puts this Windows guest in Test Mode: "
        + "Windows checks driver signatures less strictly, it trusts that third party's certificate, and a "
        + "watermark appears on the desktop. The guest has to restart for it to take effect. You can turn "
        + "sound off again, and restart, to undo it."

    // MARK: loading

    func load() async {
        do { host = try await transport.hostInfo() } catch { self.error = "\(error)" }
        await reloadShares()
        if soundAvailable { await reloadSound() }
    }

    /// The host's list changed (the VM started, stopped, was paused).
    func update(_ vm: VmSummary) { self.vm = vm }

    // MARK: what is allowed

    /// CPUs and memory are read at boot, so a VM that is not stopped cannot change them.
    var canEditResources: Bool { vm.state == .stopped && vm.activity == nil }

    /// Sound is switched on by the agent inside a running Windows guest.
    var soundAvailable: Bool { vm.bootMode == .windows && vm.state == .running && vm.activity == nil }

    var cpuChoices: [Int] { Array(1...min(32, host?.maxCpus ?? max(vm.cpus, 8))) }

    var memoryChoices: [Int] {
        let steps = [512, 1024, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, 131072]
        let limit = host?.maxMemoryMB ?? Int.max
        // The VM's current value stays selectable even when it is not one of the usual steps.
        return Set(steps.filter { $0 <= limit } + [vm.memoryMB]).sorted()
    }

    /// Why the draft cannot be saved, or nil when it can.
    var validationProblem: String? {
        guard canEditResources, let host else { return nil }
        if cpus < 1 || cpus > host.maxCpus { return "This Mac allows 1 to \(host.maxCpus) CPUs for a VM." }
        if memoryMB < 128 || memoryMB > host.maxMemoryMB {
            return "This Mac allows 128 to \(host.maxMemoryMB) MB of memory for a VM."
        }
        return nil
    }

    // MARK: saving

    /// Only what differs from the VM as it is now, and only what may change now.
    func changes() -> [(key: String, value: CBOR)] {
        var out: [(key: String, value: CBOR)] = []
        if canEditResources {
            if cpus != vm.cpus { out.append(("cpus", .uint(UInt64(cpus)))) }
            if memoryMB != vm.memoryMB { out.append(("memoryMB", .uint(UInt64(memoryMB)))) }
        }
        if !timezone.isEmpty, timezone != (vm.timezone ?? "") { out.append(("tz", .text(timezone))) }
        return out
    }

    /// Saves the draft. False when it could not be saved, with `error` saying why.
    @discardableResult
    func apply() async -> Bool {
        if let problem = validationProblem {
            error = problem
            return false
        }
        let changed = changes()
        guard !changed.isEmpty else { return true }
        do {
            _ = try await transport.send("set", [("id", .text(vm.uuid))] + changed)
            error = nil
            return true
        } catch {
            self.error = "\(error)"
            return false
        }
    }

    // MARK: shared folders

    func addShare(hostPath: String) async {
        await act { _ = try await self.transport.send("share-add", [("id", .text(self.vm.uuid)), ("hostPath", .text(hostPath))]) }
        await reloadShares()
    }

    func removeShare(_ share: Share) async {
        await act { _ = try await self.transport.send("share-remove", [("id", .text(self.vm.uuid)), ("hostPath", .text(share.hostPath))]) }
        await reloadShares()
    }

    private func reloadShares() async {
        guard let fields = try? await transport.send("share-list", [("id", .text(vm.uuid))]),
            case .array(let rows)? = DaemonClient.field(fields, "shares")
        else { return }
        shares = rows.compactMap { row in
            guard case .map(let f) = row, case .text(let hostPath)? = DaemonClient.field(f, "hostPath"),
                case .text(let guestPath)? = DaemonClient.field(f, "guestPath")
            else { return nil }
            return Share(hostPath: hostPath, guestPath: guestPath)
        }
    }

    // MARK: Windows sound

    /// Turns sound on. Nothing is sent unless the person has agreed to `testModeWarning`.
    func enableSound(consented: Bool) async {
        guard consented else {
            error = "Windows sound needs your agreement to turn on Test Mode."
            return
        }
        working = true
        defer { working = false }
        await act {
            _ = try await self.transport.send(
                "audio", [("id", .text(self.vm.uuid)), ("op", .text("enable")), ("testMode", .bool(true))])
        }
        await reloadSound()
    }

    /// Turning it off needs no consent.
    func disableSound() async {
        working = true
        defer { working = false }
        await act { _ = try await self.transport.send("audio", [("id", .text(self.vm.uuid)), ("op", .text("disable"))]) }
        await reloadSound()
    }

    private func reloadSound() async {
        guard soundAvailable,
            let fields = try? await transport.send("audio", [("id", .text(vm.uuid)), ("op", .text("status"))])
        else { return }
        soundState = GuestAudioStatus(.map(fields))?.state
    }

    private func act(_ body: () async throws -> Void) async {
        do {
            try await body()
            error = nil
        } catch {
            self.error = "\(error)"
        }
    }
}
