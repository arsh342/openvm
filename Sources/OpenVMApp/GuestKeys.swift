// GuestKeys — which key combinations stay with the Mac while a guest has the keyboard.
//
// In a Windows guest Command is the Windows key, so almost every Command shortcut means something
// there too. The rule is therefore the other way round from most apps: while the guest's screen has
// the keyboard, every key combination is the guest's, except this short fixed list. The VM view
// claims the rest before the menu bar can (DropMachineView.performKeyEquivalent), so adding a menu
// shortcut can never take a key from a guest.
import AppKit

enum GuestKeys {
    /// Whether a key press could be a menu shortcut at all. Every shortcut in openVM's menu bar holds
    /// Command (a test checks that), so a press without it is plain typing and is left alone.
    static func couldBeMenuShortcut(_ modifiers: NSEvent.ModifierFlags) -> Bool { modifiers.contains(.command) }

    /// Whether the app keeps this combination. `key` is the key without its modifiers, as
    /// `NSEvent.charactersIgnoringModifiers` gives it.
    static func keptByMac(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let held = modifiers.intersection([.command, .option, .control, .shift])
        switch (key.lowercased(), held) {
        case ("q", [.command]): return true  // Quit openVM (it asks first while a guest runs)
        case ("h", [.command]), ("h", [.command, .option]): return true  // Hide openVM, Hide Others
        case ("f", [.command, .control]): return true  // Enter or Exit Full Screen
        case ("`", [.command]), ("`", [.command, .shift]), ("~", [.command, .shift]): return true  // next window
        case (",", [.command, .option]): return true  // this VM's settings
        default: return false
        }
    }
}
