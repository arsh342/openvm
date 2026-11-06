// LibraryWindowController — the window that lists every VM.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class LibraryWindowController: NSWindowController {
    init(model: VMListModel, open: @escaping (VmSummary) -> Void, settings: @escaping (VmSummary) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "openVM"
        let frameName = "library-window"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        window.contentView = NSHostingView(rootView: VMListView(model: model, open: open, settings: settings))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
