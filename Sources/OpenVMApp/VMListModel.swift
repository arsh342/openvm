// VMListModel — the host's VMs, kept current, and the actions on them. One instance
// feeds every window and menu, so they never disagree.
import Combine
import Foundation
import OpenVMCore

@MainActor
final class VMListModel: ObservableObject {
    @Published private(set) var vms: [VmSummary] = []
    /// The last action the host refused or failed, for a banner. Only a new action
    /// (or the person dismissing it) clears it; a refresh must not hide it.
    @Published var lastError: String?
    /// Set while the host does not answer; clears when it does.
    @Published private(set) var hostProblem: String?
    /// A VM the person has asked to delete and not yet confirmed.
    @Published private(set) var pendingDelete: VmSummary?

    let transport: any HostTransport
    private let interval: Duration
    private var polling: Task<Void, Never>?

    init(transport: any HostTransport, interval: Duration = .seconds(1)) {
        self.transport = transport
        self.interval = interval
    }

    /// Starts the 1 Hz refresh. It talks only to the local socket and the registry,
    /// never to a guest, so an idle guest costs nothing.
    func begin() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func end() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        do {
            let fresh = try await transport.listVMs()
            if fresh != vms { vms = fresh }  // no republish when nothing changed
            if hostProblem != nil { hostProblem = nil }
        } catch {
            hostProblem = "openVM's host is not reachable: \(error)"
        }
    }

    func vm(uuid: String) -> VmSummary? { vms.first { $0.uuid == uuid } }

    // MARK: actions

    func start(_ vm: VmSummary) async { await act("start", vm) }
    func suspend(_ vm: VmSummary) async { await act("suspend", vm) }
    func resume(_ vm: VmSummary) async { await act("resume", vm) }

    /// Asks the guest to shut down, and waits for it.
    func stop(_ vm: VmSummary) async { await act("stop", vm) }

    /// Shuts the guest down and starts it again. A stop the host refused leaves the VM as it was.
    func restart(_ vm: VmSummary) async {
        await act("stop", vm)
        guard lastError == nil else { return }
        await act("start", vm)
    }

    /// Turns acceptance of files a VM sends on or off. It may change while the VM runs.
    func setOutbox(_ vm: VmSummary, _ on: Bool) async {
        do {
            _ = try await transport.send("set", [("id", .text(vm.uuid)), ("outbox", .bool(on))])
            await refresh()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Turns clipboard sharing for one VM on or off. It may change while the VM runs.
    func setClipboardSync(_ vm: VmSummary, _ on: Bool) async {
        do {
            _ = try await transport.send("set", [("id", .text(vm.uuid)), ("clipboard-sync", .bool(on))])
            await refresh()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Asks to delete a VM. The view confirms with the person before `confirmDelete`.
    func requestDelete(_ vm: VmSummary) {
        guard vm.state == .stopped else {
            lastError = "Stop \(vm.name) before deleting it."
            return
        }
        pendingDelete = vm
    }

    func cancelDelete() { pendingDelete = nil }

    /// Takes the VM the confirmation was shown for, rather than reading `pendingDelete`:
    /// dismissing the dialog clears that, and may happen before this runs.
    func confirmDelete(_ vm: VmSummary) async {
        pendingDelete = nil
        await delete(vm)
    }

    func delete(_ vm: VmSummary) async {
        guard vm.state == .stopped else {
            lastError = "Stop \(vm.name) before deleting it."
            return
        }
        await act("delete", vm)
        if lastError == nil { ThumbnailStore.shared.remove(vm.uuid) }
    }

    private func act(_ op: String, _ vm: VmSummary) async {
        do {
            _ = try await transport.send(op, [("id", .text(vm.uuid))])
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        await refresh()
    }
}
