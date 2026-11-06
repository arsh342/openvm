// VMToolbar — the buttons across the top of a VM's window. Which are live follows the
// VM's state (VMToolbarLogic); each one does what its label says and no more.
import AppKit

@MainActor
final class VMToolbar: NSObject, NSToolbarDelegate {
    private nonisolated enum ID {
        static let power = NSToolbarItem.Identifier("openvm.power")
        static let pause = NSToolbarItem.Identifier("openvm.pause")
        static let fullScreen = NSToolbarItem.Identifier("openvm.fullScreen")
        static let shareFolder = NSToolbarItem.Identifier("openvm.shareFolder")
        static let clipboard = NSToolbarItem.Identifier("openvm.clipboard")
        static let settings = NSToolbarItem.Identifier("openvm.settings")
    }

    let toolbar = NSToolbar(identifier: "openvm.vm-window")
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private(set) var state = ToolbarState(power: .start, pause: .disabled, fullScreenEnabled: false)

    var onPower: (PowerButton) -> Void = { _ in }
    var onPause: (PauseButton) -> Void = { _ in }
    var onFullScreen: () -> Void = {}
    var onShareFolder: () -> Void = {}
    var onClipboard: (Bool) -> Void = { _ in }
    var onSettings: () -> Void = {}

    override init() {
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
    }

    func update(_ state: ToolbarState) {
        self.state = state
        if let power = items[ID.power] {
            power.label = state.power.title
            power.toolTip = state.power.title
            power.image = symbol(state.power.symbol, state.power.title)
            power.isEnabled = state.power != .disabled
        }
        if let pause = items[ID.pause] {
            pause.label = state.pause.title
            pause.toolTip = state.pause.title
            pause.image = symbol(state.pause.symbol, state.pause.title)
            pause.isEnabled = state.pause != .disabled
        }
        items[ID.fullScreen]?.isEnabled = state.fullScreenEnabled
        if let clipboard = items[ID.clipboard] { styleClipboard(clipboard, on: state.clipboardSync) }
    }

    // MARK: NSToolbarDelegate

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.power, ID.pause, ID.fullScreen, ID.shareFolder, ID.clipboard, .flexibleSpace, ID.settings]
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    nonisolated func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self
            switch identifier {
            case ID.power: configure(item, "Power", "power", #selector(powerPressed))
            case ID.pause: configure(item, "Pause", "pause.fill", #selector(pausePressed))
            case ID.fullScreen:
                configure(item, "Full Screen", "arrow.up.left.and.arrow.down.right", #selector(fullScreenPressed))
            case ID.shareFolder:
                configure(item, "Share Folder", "folder.badge.plus", #selector(shareFolderPressed))
            case ID.clipboard:
                configure(item, "Clipboard", "doc.on.clipboard", #selector(clipboardPressed))
                styleClipboard(item, on: state.clipboardSync)
            case ID.settings: configure(item, "Settings", "gearshape", #selector(settingsPressed))
            default: return nil
            }
            items[identifier] = item
            return item
        }
    }

    private func configure(_ item: NSToolbarItem, _ label: String, _ symbolName: String, _ action: Selector) {
        item.label = label
        item.toolTip = label
        item.image = symbol(symbolName, label)
        item.action = action
    }

    /// On shows the filled symbol; off shows it crossed through, so the state reads at a glance.
    private func styleClipboard(_ item: NSToolbarItem, on: Bool) {
        let title = on ? "Clipboard sharing is on. Click to turn it off." : "Clipboard sharing is off. Click to turn it on."
        item.label = "Clipboard"
        item.toolTip = title
        item.image = symbol(on ? "doc.on.clipboard.fill" : "doc.on.clipboard", title)
    }

    private func symbol(_ name: String, _ description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }

    @objc private func powerPressed() { onPower(state.power) }
    @objc private func pausePressed() { onPause(state.pause) }
    @objc private func fullScreenPressed() { onFullScreen() }
    @objc private func shareFolderPressed() { onShareFolder() }
    @objc private func clipboardPressed() { onClipboard(!state.clipboardSync) }
    @objc private func settingsPressed() { onSettings() }
}
