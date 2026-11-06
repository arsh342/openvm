// WindowRegistry — one window per VM, reused when it is opened again.
import AppKit
import OpenVMCore
import OpenVMHost

@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var controllers: [String: VMWindowController] = [:]

    /// Opens (or brings forward) the window for a VM.
    func show(_ vm: VmSummary, model: VMListModel) {
        let controller =
            controllers[vm.uuid]
            ?? VMWindowController(vm: vm, model: model) { vm in
                SettingsWindows.shared.show(vm, transport: model.transport)
            }
        controllers[vm.uuid] = controller
        controller.update(vm)
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// A guest has sent files: say so in its window, and in the Dock if the app is in the background.
    func received(_ receipt: OutboxReceipt) {
        guard let controller = controllers[receipt.uuid] else { return }
        controller.showNotice(ReceiptMessage.subtitle(receipt))
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Pushes the host's latest list to the windows that are open, and drops the
    /// controllers of VMs that no longer exist.
    func update(_ vms: [VmSummary]) {
        let known = Set(vms.map(\.uuid))
        for uuid in controllers.keys where !known.contains(uuid) { controllers[uuid] = nil }
        for vm in vms { controllers[vm.uuid]?.update(vm) }
        SettingsWindows.shared.update(vms)
    }
}
