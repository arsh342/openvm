// VMSettingsWindow — one VM's settings window, reused when it is opened again.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class VMSettingsWindowController: NSWindowController {
    let model: VMSettingsModel

    init(vm: VmSummary, transport: any HostTransport) {
        model = VMSettingsModel(vm: vm, transport: transport)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 740),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(vm.name) Settings"
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: VMSettingsView(model: model) { [weak window] in window?.close() })
        Task { await model.load() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class SettingsWindows {
    static let shared = SettingsWindows()
    private var controllers: [String: VMSettingsWindowController] = [:]

    func show(_ vm: VmSummary, transport: any HostTransport) {
        let controller = controllers[vm.uuid] ?? VMSettingsWindowController(vm: vm, transport: transport)
        controllers[vm.uuid] = controller
        controller.model.update(vm)
        Task { await controller.model.load() }  // reflect what changed while it was closed
        controller.showWindow(nil)
        NSApp.activate()
    }

    func update(_ vms: [VmSummary]) {
        let known = Set(vms.map(\.uuid))
        for uuid in controllers.keys where !known.contains(uuid) { controllers[uuid] = nil }
        for vm in vms { controllers[vm.uuid]?.model.update(vm) }
    }
}
