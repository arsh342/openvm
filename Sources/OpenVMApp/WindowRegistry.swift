// WindowRegistry — one window per VM, reused when it is opened again.
import AppKit
import OpenVMCore

@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var controllers: [String: VMWindowController] = [:]

    /// Opens (or brings forward) the window for a VM.
    func show(_ vm: VmSummary, onStart: @escaping (VmSummary) -> Void) {
        let controller = controllers[vm.uuid] ?? VMWindowController(vm: vm, onStart: onStart)
        controllers[vm.uuid] = controller
        controller.update(vm)
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// Pushes the host's latest list to the windows that are open, and drops the
    /// controllers of VMs that no longer exist.
    func update(_ vms: [VmSummary]) {
        let known = Set(vms.map(\.uuid))
        for uuid in controllers.keys where !known.contains(uuid) { controllers[uuid] = nil }
        for vm in vms { controllers[vm.uuid]?.update(vm) }
    }
}
