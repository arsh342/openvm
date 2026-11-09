// ClipboardSync against a fake pasteboard and a fake host: what crosses, and what never does.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

@MainActor
final class FakePasteboard: PasteboardAccess {
    var changeCount = 1
    var isConcealed = false
    var string: String?
    func text() -> String? { string }
    func setText(_ text: String) -> Int {
        string = text
        changeCount += 1
        return changeCount
    }
    /// What the person does in another app.
    func copy(_ text: String?, concealed: Bool = false) {
        string = text
        isConcealed = concealed
        changeCount += 1
    }
}

@MainActor
struct ClipboardSyncTests {
    private func make(sync: Bool = true) -> (ClipboardSync, FakePasteboard, FakeTransport) {
        let board = FakePasteboard()
        let host = FakeTransport()
        let vm = FakeTransport.summary(state: "running", clipboardSync: sync)
        return (ClipboardSync(vm: vm, transport: host, pasteboard: board), board, host)
    }

    @Test func macTextIsSentWhenTheWindowComesToTheFront() async {
        let (sync, board, host) = make()
        board.copy("hello")
        await sync.focusGained()
        #expect(host.arg("clipboard-write", "text") == .text("hello"))
        #expect(host.arg("clipboard-write", "id") == .text("uuid-w"))
    }

    @Test func theSameTextIsNotSentTwice() async {
        let (sync, board, host) = make()
        board.copy("hello")
        await sync.focusGained()
        await sync.focusGained()
        #expect(host.calls.filter { $0 == "clipboard-write" }.count == 1)
    }

    @Test func concealedItemsNeverReachTheGuestAndTheWindowSaysSo() async {
        let (sync, board, host) = make()
        var notice: String?
        sync.onNotice = { notice = $0 }
        board.copy("hunter2", concealed: true)
        await sync.focusGained()
        #expect(!host.calls.contains("clipboard-write"))
        #expect(notice?.contains("private") == true)
    }

    @Test func guestTextComesBackWhenTheWindowLosesFocus() async {
        let (sync, board, host) = make()
        host.respond("clipboard-read", with: [("text", .text("from guest"))])
        await sync.focusLost()
        #expect(board.string == "from guest")
    }

    @Test func textTheMacGaveTheGuestIsNotWrittenBack() async {
        let (sync, board, host) = make()
        board.copy("hello")
        await sync.focusGained()
        host.respond("clipboard-read", with: [("text", .text("hello"))])
        let changes = board.changeCount
        await sync.focusLost()
        #expect(board.changeCount == changes)  // the Mac's own clipboard is left alone
    }

    @Test func pulledTextIsNotPushedBackOnTheNextFocus() async {
        let (sync, board, host) = make()
        host.respond("clipboard-read", with: [("text", .text("from guest"))])
        await sync.focusLost()
        await sync.focusGained()
        #expect(!host.calls.contains("clipboard-write"))
        #expect(board.string == "from guest")
    }

    @Test func aGuestWithNoDesktopYetIsTriedAgainNextTime() async {
        let (sync, board, host) = make()
        board.copy("hello")
        host.fail("clipboard-write", with: NSError(domain: "t", code: 1))
        await sync.focusGained()
        host.fail("clipboard-write", with: NSError(domain: "t", code: 1))  // still refusing
        await sync.focusGained()
        #expect(host.calls.filter { $0 == "clipboard-write" }.count == 2)
    }

    @Test func aFailedReadLeavesTheMacAlone() async {
        let (sync, board, host) = make()
        board.copy("mine")
        host.fail("clipboard-read", with: NSError(domain: "t", code: 1))
        await sync.focusLost()
        #expect(board.string == "mine")
    }

    @Test func aVmWithSharingOffMovesNothing() async {
        let (sync, board, host) = make(sync: false)
        board.copy("hello")
        host.respond("clipboard-read", with: [("text", .text("from guest"))])
        await sync.focusGained()
        await sync.focusLost()
        #expect(host.calls.isEmpty)
        #expect(board.string == "hello")
    }

    @Test func turningItOnLaterStartsSharing() async {
        let (sync, board, host) = make(sync: false)
        board.copy("hello")
        sync.setEnabled(true)
        await sync.focusGained()
        #expect(host.calls == ["clipboard-write"])
    }
}
