// When the Mac's clipboard goes to a guest and the guest's comes back, and when it must not.
// Pure decisions, so each edge (our own writes, passwords, nothing new) is pinned without a window.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct ClipboardPolicyTests {
    @Test func unchangedPasteboardIsNotPushed() {
        var policy = ClipboardPolicy()
        let r1 = policy.onFocusGained(changeCount: 5, concealed: false, byteCount: 10)
        #expect(r1)
        policy.didPush("hello")
        let unchanged = policy.onFocusGained(changeCount: 5, concealed: false, byteCount: 10)  // nothing new since
        #expect(!unchanged)
        let changed = policy.onFocusGained(changeCount: 6, concealed: false, byteCount: 10)  // something was copied
        #expect(changed)
    }

    /// A password manager marks what it copies as concealed. It must never reach a guest.
    @Test func concealedItemsAreNotPushed() {
        var policy = ClipboardPolicy()
        let r2 = policy.onFocusGained(changeCount: 1, concealed: true, byteCount: 12)
        #expect(!r2)
        #expect(policy.lastSkip == .concealed)
        // and it is not remembered as synced: the same change is still refused next time
        let r3 = policy.onFocusGained(changeCount: 1, concealed: true, byteCount: 12)
        #expect(!r3)
    }

    /// 512 KiB is what both guests take: the Windows agent's clipboard buffers are half the frame.
    @Test func oversizedTextIsSkipped() {
        var policy = ClipboardPolicy()
        #expect(ClipboardPolicy.maxTextBytes == OVMC.maxPayload / 2)
        let r4 = policy.onFocusGained(changeCount: 1, concealed: false, byteCount: ClipboardPolicy.maxTextBytes)
        #expect(r4)
        policy.didPush("x")
        let r5 = policy.onFocusGained(changeCount: 2, concealed: false, byteCount: ClipboardPolicy.maxTextBytes + 1)
        #expect(!r5)
        #expect(policy.lastSkip == .tooLarge)
    }

    @Test func aSuccessfulPushClearsAnEarlierSkip() {
        var policy = ClipboardPolicy()
        _ = policy.onFocusGained(changeCount: 1, concealed: true, byteCount: 5)
        #expect(policy.lastSkip == .concealed)
        let r6 = policy.onFocusGained(changeCount: 2, concealed: false, byteCount: 5)
        #expect(r6)
        #expect(policy.lastSkip == nil)
    }

    @Test func aPasteboardWithNoTextIsNotPushed() {
        var policy = ClipboardPolicy()
        let noText = policy.onFocusGained(changeCount: 1, concealed: false, byteCount: 0)  // an image, say
        #expect(!noText)
        #expect(policy.lastSkip == nil)  // not worth telling anyone
    }

    @Test func aFailedPushIsTriedAgainOnTheNextFocus() {
        var policy = ClipboardPolicy()
        let r7 = policy.onFocusGained(changeCount: 3, concealed: false, byteCount: 4)
        #expect(r7)
        policy.pushFailed()  // the guest had no desktop session yet
        let r8 = policy.onFocusGained(changeCount: 3, concealed: false, byteCount: 4)
        #expect(r8)
    }

    // MARK: the other way

    @Test func guestTextComesBackToTheMac() {
        var policy = ClipboardPolicy()
        let r9 = policy.onFocusLost(guestText: "from the guest")
        #expect(r9 == "from the guest")
    }

    /// What we just wrote to the Mac is not a new Mac copy, so it is not sent back.
    @Test func pulledTextIsNotPushedBack() {
        var policy = ClipboardPolicy()
        let r10 = policy.onFocusLost(guestText: "from the guest")
        #expect(r10 == "from the guest")
        policy.didPull(changeCount: 8, text: "from the guest")  // writing bumped the Mac's change count
        let r11 = policy.onFocusGained(changeCount: 8, concealed: false, byteCount: 14)
        #expect(!r11)
        let later = policy.onFocusGained(changeCount: 9, concealed: false, byteCount: 14)  // a real copy after
        #expect(later)
    }

    @Test func emptyGuestClipboardLeavesTheMacAlone() {
        var policy = ClipboardPolicy()
        let r12 = policy.onFocusLost(guestText: nil)
        #expect(r12 == nil)
        let r13 = policy.onFocusLost(guestText: "")
        #expect(r13 == nil)
    }

    /// The guest still holds what we gave it. Writing it back would replace the Mac's clipboard
    /// (an image, rich text) with plain text for no reason.
    @Test func anUnchangedGuestClipboardLeavesTheMacAlone() {
        var policy = ClipboardPolicy()
        let r14 = policy.onFocusGained(changeCount: 1, concealed: false, byteCount: 5)
        #expect(r14)
        policy.didPush("hello")
        let r15 = policy.onFocusLost(guestText: "hello")
        #expect(r15 == nil)
        let r16 = policy.onFocusLost(guestText: "changed in the guest")
        #expect(r16 == "changed in the guest")
    }

    @Test func theSameGuestTextIsNotPulledTwice() {
        var policy = ClipboardPolicy()
        let r17 = policy.onFocusLost(guestText: "x")
        #expect(r17 == "x")
        policy.didPull(changeCount: 4, text: "x")
        let r18 = policy.onFocusLost(guestText: "x")
        #expect(r18 == nil)
    }

    @Test func guestTextThatIsTooLargeIsNotPulled() {
        var policy = ClipboardPolicy()
        let big = String(repeating: "a", count: ClipboardPolicy.maxTextBytes + 1)
        let r19 = policy.onFocusLost(guestText: big)
        #expect(r19 == nil)
        #expect(policy.lastSkip == .tooLarge)
    }

    // MARK: the switch

    @Test func disabledSyncDoesNothing() {
        var policy = ClipboardPolicy(enabled: false)
        let r20 = policy.onFocusGained(changeCount: 1, concealed: false, byteCount: 5)
        #expect(!r20)
        let r21 = policy.onFocusLost(guestText: "from the guest")
        #expect(r21 == nil)
        policy.enabled = true
        let r22 = policy.onFocusGained(changeCount: 1, concealed: false, byteCount: 5)
        #expect(r22)
    }
}
