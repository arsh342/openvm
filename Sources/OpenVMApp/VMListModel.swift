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
    /// openVM's installer cache: finished installers and downloads in flight.
    @Published private(set) var installers: [InstallerRow] = []

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
            await refreshInstallers()
        } catch {
            hostProblem = "openVM's host is not reachable: \(error)"
        }
    }

    func vm(uuid: String) -> VmSummary? { vms.first { $0.uuid == uuid } }

    /// A VM by name or uuid. One the list does not have yet (the wizard has just made it, and the next poll is
    /// up to a second away; a link arrived before the first poll) is looked for again in a fresh list.
    func find(_ reference: String) async -> VmSummary? {
        func lookup() -> VmSummary? {
            vms.first { $0.name == reference || $0.uuid.lowercased() == reference.lowercased() }
        }
        if let found = lookup() { return found }
        await refresh()
        return lookup()
    }

    // MARK: installers

    /// A host from before downloads does not know the op: then there are none.
    private func refreshInstallers() async {
        var fresh: [InstallerRow] = []
        if let reply = try? await transport.send("installers-list", []),
            case .array(let rows)? = DaemonClient.field(reply, "installers")
        {
            fresh = rows.compactMap(InstallerRow.init(row:))
        }
        if fresh != installers { installers = fresh }
    }

    /// The names of the installers that are downloading now, for the quit dialog and the menu-bar icon.
    var downloading: [InstallerRow] { installers.filter(\.downloading) }

    /// Stops a download. What it has is kept, so it can be picked up again.
    func pauseDownload(_ row: InstallerRow) async {
        guard let id = row.taskId else { return }
        _ = try? await transport.send("task-cancel", [("taskId", .text(id))])
        await refreshInstallers()
    }

    /// Starts, or picks up, the download of a catalog entry.
    func startDownload(entry: String) async {
        do {
            _ = try await transport.send(
                "task-start", [("kind", .text("fetch-iso")), ("entry", .text(entry))])
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        await refreshInstallers()
    }

    func removeInstaller(entry: String) async {
        do {
            _ = try await transport.send("installer-remove", [("entry", .text(entry))])
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
        await refreshInstallers()
    }

    // MARK: actions

    func start(_ vm: VmSummary) async { await act("start", vm) }
    func suspend(_ vm: VmSummary) async { await act("suspend", vm) }
    func resume(_ vm: VmSummary) async { await act("resume", vm) }

    /// Asks the guest to shut down, and waits for it.
    func stop(_ vm: VmSummary) async { await act("stop", vm) }

    /// Takes the installer ISO out of a stopped VM, so it starts from its disk.
    func ejectInstaller(_ vm: VmSummary) async { await act("eject-installer", vm) }

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

    /// Deletes a stopped VM and its disk. The caller has asked the person first (VMCommand.delete).
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
