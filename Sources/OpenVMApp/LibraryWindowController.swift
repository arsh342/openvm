// LibraryWindowController — the window that lists every VM: a sidebar of groups, a sortable table, and a
// detail pane, under a standard toolbar (New, Start or Shut Down for the selection, search). With it in
// front, a Virtual Machine command in the menu bar is for the VM selected here.
import AppKit
import Combine
import OpenVMCore
import SwiftUI

extension NSToolbarItem.Identifier {
    static let newVM = NSToolbarItem.Identifier("new-vm")
    static let search = NSToolbarItem.Identifier("search")
    /// A VM command's toolbar item is named after the command, so `VMCommand.from` finds it.
    static func command(_ command: VMCommand) -> NSToolbarItem.Identifier { .init(command.rawValue) }
}

@MainActor
final class LibraryWindowController: NSWindowController, NSMenuItemValidation, NSToolbarDelegate,
    NSToolbarItemValidation, NSSearchFieldDelegate
{
    private let nav = LibraryNav()
    private let model: VMListModel
    private let context: VMCommandContext
    private let newVM: (NewVMStart) -> Void
    private let gallery: GalleryModel
    private var subscription: AnyCancellable?

    init(model: VMListModel, context: VMCommandContext, newVM: @escaping (NewVMStart) -> Void) {
        self.model = model
        self.context = context
        self.newVM = newVM
        let gallery = GalleryModel(transport: model.transport)
        self.gallery = gallery
        let nav = self.nav
        let run: (VMCommand, VmSummary) -> Void = { command, vm in
            Task { await command.perform(on: vm, in: context) }
        }

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: LibrarySidebarView(model: model, nav: nav)))
        sidebar.minimumThickness = 160
        sidebar.maximumThickness = 260
        split.addSplitViewItem(sidebar)
        let table = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: VMTableView(model: model, nav: nav, run: run, newVM: newVM, gallery: gallery)))
        table.minimumThickness = 420
        split.addSplitViewItem(table)
        let detail = NSSplitViewItem(
            inspectorWithViewController: NSHostingController(
                rootView: VMDetailPane(
                    model: model, nav: nav, thumbnails: .shared, settings: .shared, run: run)))
        detail.minimumThickness = 250
        detail.maximumThickness = 340
        split.addSplitViewItem(detail)
        split.splitView.autosaveName = "library-split"

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1040, height: 620))
        window.contentMinSize = NSSize(width: 860, height: 440)
        window.title = "openVM"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        let frameName = "library-window-3"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "library")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // A VM that goes away takes the selection with it; the first VM is selected instead, so the
        // menu bar's commands have something to act on.
        subscription = model.$vms.sink { [weak nav] vms in
            guard let nav else { return }
            let wanted = LibraryNav.resolve(nav.selection, in: vms)
            if wanted != nav.selection { nav.selection = wanted }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: commands for the selected VM

    /// The VM selected in the table, which the menu bar's and the toolbar's commands act on.
    private var selected: VmSummary? { LibraryNav.selectedVM(nav.selection, in: model.vms) }

    @objc func performVMCommand(_ sender: Any?) {
        guard let command = VMCommand.from(sender), let vm = selected else { return }
        Task { await command.perform(on: vm, in: context) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == VMCommand.action { return VMCommand.validate(item, for: selected) }
        return true
    }

    @objc private func newVirtualMachine(_ sender: Any?) { newVM(.gallery) }

    /// The free space on the gallery's tiles is read each time the window comes up.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        Task { await gallery.load() }
    }

    // MARK: toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar, .sidebarTrackingSeparator, .newVM, .command(.power), .flexibleSpace, .search,
            .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.command(.pause), .command(.settings), .space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .newVM:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "New"
            item.paletteLabel = "New Virtual Machine"
            item.toolTip = "Create a new virtual machine"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Virtual Machine")
            item.target = self
            item.action = #selector(newVirtualMachine(_:))
            item.isBordered = true
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField.placeholderString = "Search"
            item.searchField.delegate = self
            item.searchField.setAccessibilityLabel("Search virtual machines")
            return item
        default:
            guard let command = VMCommand(rawValue: identifier.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.target = self
            item.action = VMCommand.action
            item.isBordered = true
            command.show(command.state(for: selected), on: item)
            return item
        }
    }

    /// AppKit asks before it draws the toolbar: a command's item follows the selected VM.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let command = VMCommand.from(item) else { return true }
        let state = command.state(for: selected)
        command.show(state, on: item)
        return state.enabled
    }

    // MARK: search

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSSearchField { nav.search = field.stringValue }
    }
}
