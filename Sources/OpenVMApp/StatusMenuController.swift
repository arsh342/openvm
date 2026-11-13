// StatusMenuController — the menu-bar icon and its menu (MachineMenus builds the menu). The icon can be
// turned off in the app's Settings; the Dock icon then stays instead (QuitPolicy.activationPolicy).
import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var subscription: AnyCancellable?

    init(menus: MachineMenus, settings: AppSettingsModel) {
        super.init()
        item.button?.image = MenuBarGlyph.image()
        item.button?.setAccessibilityLabel("openVM")
        item.menu = menus.statusMenu()
        subscription = settings.$showsMenuBarIcon.sink { [weak self] shown in self?.item.isVisible = shown }
    }
}
