// StatusMenuController — the menu-bar icon and the popover it opens.
import AppKit
import OpenVMCore
import SwiftUI

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()

    init(
        model: VMListModel, act: @escaping (VMAction, VmSummary) -> Void, showLibrary: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "openVM")
            button.target = self
            button.action = #selector(toggle(_:))
        }
        // Closing the popover on any click is the menu-bar convention.
        popover.behavior = .transient
        let host = NSHostingController(
            rootView: StatusPopoverView(
                model: model,
                act: { [weak self] action, vm in
                    self?.popover.performClose(nil)
                    act(action, vm)
                },
                showLibrary: { [weak self] in
                    self?.popover.performClose(nil)
                    showLibrary()
                },
                quit: { [weak self] in
                    self?.popover.performClose(nil)
                    quit()
                }))
        host.sizingOptions = .preferredContentSize  // the popover is as tall as its list
        popover.contentViewController = host
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
