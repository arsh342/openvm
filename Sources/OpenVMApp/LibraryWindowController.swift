// LibraryWindowController — the window that lists every VM: a Settings-style sidebar and the page
// for what is chosen.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    private let nav = LibraryNav()

    init(
        model: VMListModel, open: @escaping (VmSummary) -> Void, settings: @escaping (VmSummary) -> Void,
        newVM: @escaping () -> Void
    ) {
        let nav = self.nav
        let window = SidebarWindow.make(
            size: NSSize(width: 980, height: 600), minSize: NSSize(width: 760, height: 460), title: "openVM",
            sidebar: LibrarySidebarView(model: model, nav: nav, newVM: newVM),
            detail: LibraryDetailView(
                model: model, nav: nav, thumbnails: .shared, open: open, settings: settings, newVM: newVM))
        let frameName = "library-window-split"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
