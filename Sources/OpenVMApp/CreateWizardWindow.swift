// CreateWizardWindow — the window the creation wizard lives in. It is not modal, so a VM's window
// can be watched while it installs. Closing it mid-run asks first, because that cancels the run.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class CreateWizardWindowController: NSWindowController, NSWindowDelegate {
    let model: CreateWizardModel
    private var closing = false

    init(transport: any HostTransport, existingNames: [String], openWindow: @escaping (String) -> Void) {
        model = CreateWizardModel(transport: transport, existingNames: existingNames, openWindow: openWindow)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "New Virtual Machine"
        window.center()
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: CreateWizardView(model: model) { [weak self] in self?.closeNow() })
        Task { await model.load() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func closeNow() {
        closing = true
        window?.close()
        closing = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // While a cancel is finishing, the window stays: closing it now would hide the cleanup.
        if model.cancelling { return false }
        guard !closing, model.page == .working else { return true }
        let alert = NSAlert()
        alert.messageText = "Cancel creating \(model.name)?"
        alert.informativeText = "This stops the installation and removes everything created for it so far."
        alert.addButton(withTitle: "Cancel and Remove")
        alert.addButton(withTitle: "Keep Going")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { @MainActor in
                await self.model.cancel()
                self.closeNow()
            }
        }
        return false
    }
}
