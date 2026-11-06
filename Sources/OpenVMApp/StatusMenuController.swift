// StatusMenuController — the menu-bar icon and its menu (MachineMenus builds the menu).
import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(menus: MachineMenus) {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "openVM")
        item.menu = menus.statusMenu()
    }
}
