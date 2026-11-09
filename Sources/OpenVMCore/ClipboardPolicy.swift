// ClipboardPolicy — when the Mac's clipboard goes to a guest and the guest's comes back, and when
// it must not. Pure decisions over a few numbers, so every edge is testable without a window.
//
// The design is "on focus": the Mac's text is pushed when the VM's window becomes the one in front,
// and the guest's text is pulled when it stops being. That needs no polling and no change to the
// guest agents, so an idle guest costs nothing. Only text, only when something is new.
import Foundation

public nonisolated struct ClipboardPolicy: Sendable {
    /// What both guests take. The frame is 1 MiB, but the Windows agent's clipboard buffers are half
    /// of that, so text above this would be accepted by one guest and silently refused by the other.
    public static let maxTextBytes = OVMC.maxPayload / 2

    public enum Skip: Equatable, Sendable {
        /// Marked concealed by the app that copied it (a password manager): never shared.
        case concealed
        case tooLarge
    }

    /// Per-VM switch. Off means nothing moves in either direction.
    public var enabled: Bool
    /// Why the last change was not shared, for a notice; cleared by the next one that is.
    public private(set) var lastSkip: Skip?

    /// The Mac clipboard's change count as of the last thing that was synced. A write of our own
    /// (pulled text) updates it, so that write is not mistaken for something the person copied.
    private var syncedChangeCount: Int?
    /// The text the Mac and the guest last agreed on.
    private var agreedText: String?

    public init(enabled: Bool = true) { self.enabled = enabled }

    // MARK: Mac to guest

    /// The VM's window came to the front. True means: send the Mac's text to the guest.
    public mutating func onFocusGained(changeCount: Int, concealed: Bool, byteCount: Int) -> Bool {
        guard enabled else { return false }
        if syncedChangeCount == changeCount { return false }  // nothing new since the last sync
        if concealed {
            lastSkip = .concealed
            return false
        }
        guard byteCount > 0 else { return false }  // no text on it (an image, say)
        if byteCount > Self.maxTextBytes {
            lastSkip = .tooLarge
            return false
        }
        syncedChangeCount = changeCount
        lastSkip = nil
        return true
    }

    /// The text reached the guest.
    public mutating func didPush(_ text: String) { agreedText = text }

    /// It did not (the guest has no desktop session yet): the next focus tries again.
    public mutating func pushFailed() { syncedChangeCount = nil }

    // MARK: guest to Mac

    /// The VM's window stopped being in front. Returns the text to put on the Mac's clipboard, or nil
    /// to leave it alone: the guest has nothing, or still holds what we gave it (writing it back would
    /// replace an image or rich text on the Mac with plain text for no reason).
    public mutating func onFocusLost(guestText: String?) -> String? {
        guard enabled, let text = guestText, !text.isEmpty else { return nil }
        guard text != agreedText else { return nil }
        if text.utf8.count > Self.maxTextBytes {
            lastSkip = .tooLarge
            return nil
        }
        return text
    }

    /// The text was written to the Mac's clipboard, which moved its change count.
    public mutating func didPull(changeCount: Int, text: String) {
        syncedChangeCount = changeCount
        agreedText = text
    }
}
