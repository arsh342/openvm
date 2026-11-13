// LibraryWindowController — the window that lists every VM: a sidebar and the page for what is chosen.
// With it in front, a Virtual Machine command in the menu bar is for the VM chosen here.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController, NSMenuItemValidation {
    private let nav = LibraryNav()
    private let model: VMListModel
    private let context: VMCommandContext

    init(model: VMListModel, context: VMCommandContext, newVM: @escaping () -> Void) {
        self.model = model
        self.context = context
        let nav = self.nav
        let run: (VMCommand, VmSummary) -> Void = { command, vm in
            Task { await command.perform(on: vm, in: context) }
        }
        let window = SidebarWindow.make(
            size: NSSize(width: 980, height: 600), minSize: NSSize(width: 760, height: 460), title: "openVM",
            sidebar: LibrarySidebarView(model: model, nav: nav, newVM: newVM),
            detail: LibraryDetailView(model: model, nav: nav, thumbnails: .shared, run: run, newVM: newVM))
        let frameName = "library-window-split"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The VM chosen in the library, which the menu bar's commands act on.
    private var selected: VmSummary? { LibraryNav.selectedVM(nav.selection, in: model.vms) }

    @objc func performVMCommand(_ sender: Any?) {
        guard let command = VMCommand.from(sender), let vm = selected else { return }
        Task { await command.perform(on: vm, in: context) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == VMCommand.action { return VMCommand.validate(item, for: selected) }
        return true
    }
}
