// Which key combinations stay with the Mac while a guest has the keyboard. Everything else is the guest's.
import AppKit
import Testing

@testable import OpenVMApp

struct GuestKeysTests {
    @Test func theMacKeepsAShortFixedList() {
        #expect(GuestKeys.keptByMac(key: "q", modifiers: [.command]))
        #expect(GuestKeys.keptByMac(key: "h", modifiers: [.command]))
        #expect(GuestKeys.keptByMac(key: "h", modifiers: [.command, .option]))
        #expect(GuestKeys.keptByMac(key: "f", modifiers: [.command, .control]))
        #expect(GuestKeys.keptByMac(key: "`", modifiers: [.command]))
        #expect(GuestKeys.keptByMac(key: ",", modifiers: [.command, .option]))
    }

    /// In a Windows guest Command is the Windows key: copy, paste, close, new, minimize and the rest
    /// are the guest's, whatever the menu bar uses them for.
    @Test func everythingElseIsTheGuests() {
        for key in ["c", "v", "x", "a", "z", "w", "n", "m", "0", ",", "s", "o", "r", "d", "e", "l", "t"] {
            #expect(!GuestKeys.keptByMac(key: key, modifiers: [.command]), "Command-\(key)")
        }
        #expect(!GuestKeys.keptByMac(key: "z", modifiers: [.command, .shift]))
        #expect(!GuestKeys.keptByMac(key: "q", modifiers: [.command, .shift]))  // not Quit: a different key
        #expect(!GuestKeys.keptByMac(key: "f", modifiers: [.command]))  // only Control-Command-F is full screen
        #expect(!GuestKeys.keptByMac(key: "\u{8}", modifiers: [.command]))  // Delete… must not fire from a guest
    }

    /// Caps Lock and the keypad bit ride along on real events and must not change the answer.
    @Test func otherFlagsDoNotMatter() {
        #expect(GuestKeys.keptByMac(key: "Q", modifiers: [.command, .capsLock]))
        #expect(GuestKeys.keptByMac(key: "h", modifiers: [.command, .numericPad]))
    }

    /// Every shortcut the Mac keeps is one the menu bar really has, so the list cannot drift into
    /// keeping keys for nothing. And every other menu shortcut goes to the guest.
    @Test @MainActor func theListMatchesTheMenuBar() async {
        let host = FakeTransport()
        let model = VMListModel(transport: host)
        let context = VMCommandContext(
            model: model, openWindow: { _ in }, showSettings: { _ in }, shareFolder: { _ in }, confirmDelete: { _ in })
        let menus = MachineMenus(
            model: model, context: context,
            actions: MachineMenuActions(showLibrary: {}, newVM: {}, lastUsed: { nil }, use: { _ in }))
        let menu = AppMenu(model: model, machine: menus, showLibrary: {}, newVM: {}, showSettings: {}, openVM: { _ in }).build()
        var kept: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty,
                    GuestKeys.keptByMac(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
                {
                    kept.append(item.title)
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)
        #expect(kept.sorted() == ["Enter Full Screen", "Hide Others", "Hide openVM", "Quit openVM", "Settings…"])
    }
}
