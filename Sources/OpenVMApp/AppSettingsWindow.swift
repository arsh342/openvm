// AppSettingsWindow — the one window for the app's settings, reused when it is opened again.
import AppKit
import SwiftUI

@MainActor
final class AppSettingsWindowController: NSWindowController {
    init(model: AppSettingsModel, vms: VMListModel) {
        let hosting = NSHostingController(
            rootView: AppSettingsView(model: model, installers: InstallerSettings(vms: vms)))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
