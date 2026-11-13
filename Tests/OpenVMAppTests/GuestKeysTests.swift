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

    /// Plain typing is never claimed from the normal path: only a press with Command could be a menu's.
    @Test func onlyCommandCombinationsAreClaimed() {
        #expect(GuestKeys.couldBeMenuShortcut([.command]))
        #expect(GuestKeys.couldBeMenuShortcut([.command, .shift]))
        #expect(!GuestKeys.couldBeMenuShortcut([]))
        #expect(!GuestKeys.couldBeMenuShortcut([.shift]))
        #expect(!GuestKeys.couldBeMenuShortcut([.control]))
        #expect(!GuestKeys.couldBeMenuShortcut([.option]))
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
            model: model, openWindow: { _ in }, showSettings: { _ in }, shareFolder: { _ in },
            confirmDelete: { _ in })
        let menus = MachineMenus(
            model: model, context: context,
            actions: MachineMenuActions(showLibrary: {}, newVM: {}, lastUsed: { nil }, use: { _ in }))
        let menu = AppMenu(
            model: model, machine: menus, showLibrary: {}, newVM: {}, showSettings: {}, openVM: { _ in }
        ).build()
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
        var withoutCommand: [String] = []
        func check(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty, !GuestKeys.couldBeMenuShortcut(item.keyEquivalentModifierMask)
                {
                    withoutCommand.append(item.title)
                }
                if let submenu = item.submenu { check(submenu) }
            }
        }
        check(menu)
        #expect(withoutCommand.isEmpty)  // so claiming only Command combinations covers every menu shortcut
        walk(menu)
        #expect(
            kept.sorted() == ["Enter Full Screen", "Hide Others", "Hide openVM", "Quit openVM", "Settings…"])
    }
}

/// The menu-bar mark is the app icon's two screens, as a template image.
@MainActor
struct MenuBarGlyphTests {
    @Test func itIsATemplateTheSizeOfAMenuBarIconAndNamed() {
        let glyph = MenuBarGlyph.image()
        #expect(glyph.isTemplate)  // so the menu bar tints it for light and dark
        #expect(glyph.size == NSSize(width: 18, height: 18))
        #expect(glyph.accessibilityDescription == "openVM")
    }

    /// It draws something, and leaves the corner the two screens do not reach empty.
    @Test func itDrawsTheTwoScreens() throws {
        let side = 72
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        MenuBarGlyph.image(side: CGFloat(side)).draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        #expect(alpha(54, 50) > 0.9)  // inside the guest's filled screen, lower right
        #expect(alpha(24, 26) < 0.1)  // inside the host's outline: empty
        #expect(alpha(68, 6) < 0.1)  // the top right corner, which neither screen reaches
    }
}

/// The shapes are the icon's own, so the two cannot drift apart.
struct MenuBarGlyphShapeTests {
    @Test func theGlyphUsesTheIconsShapes() throws {
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/build/AppIcon.icon/Assets")
        let back = try String(contentsOf: assets.appendingPathComponent("back.svg"), encoding: .utf8)
        let front = try String(contentsOf: assets.appendingPathComponent("front.svg"), encoding: .utf8)
        #expect(back.contains(#"x="174" y="232" width="580" height="430" rx="72""#))
        #expect(front.contains(#"x="400" y="430" width="450" height="340" rx="64""#))
        #expect(!front.contains("<path"))  // the guest's screen is plain: no power mark
    }
}
