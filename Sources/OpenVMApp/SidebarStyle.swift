// SidebarStyle — the look the library and the creation window share, taken from System Settings: a
// translucent sidebar that runs up behind the traffic lights, rows with a coloured rounded-square icon,
// and a content pane beside it.
import AppKit
import SwiftUI

/// A white symbol on a coloured rounded square, as in a Settings sidebar row.
struct SidebarIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.gradient))
    }
}

enum SidebarWindow {
    /// A window whose left pane is a real sidebar (translucent, collapsible) and whose right pane is the
    /// content. The title bar is transparent and the content runs under it, so the traffic lights sit on
    /// the sidebar.
    @MainActor
    static func make<Sidebar: View, Detail: View>(
        size: NSSize, minSize: NSSize, sidebarWidth: CGFloat = 240, title: String,
        sidebar: Sidebar, detail: Detail
    ) -> NSWindow {
        let split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar))
        side.minimumThickness = sidebarWidth - 30
        side.maximumThickness = sidebarWidth + 60
        side.canCollapse = true
        split.addSplitViewItem(side)
        let content = NSHostingController(rootView: detail)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = nil

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = split
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.isReleasedWhenClosed = false
        return window
    }
}
