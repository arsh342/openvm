// Tests for parsing audio replies.
import Testing

@testable import OpenVMCore

@Suite struct GuestAudioTests {
    @Test func statusParses() {
        let reply = CBOR.map([
            ("device", .text("VirtIO SoundCard")), ("running", .bool(true)),
            ("rate", .uint(48000)),
        ])
        #expect(
            GuestAudioStatus(reply)
                == GuestAudioStatus(device: "VirtIO SoundCard", running: true, rate: 48000))
    }

    @Test func windowsReportsAStateAndNoRunningFlag() {
        let reply = CBOR.map([("state", .text("on")), ("device", .text("XCB VirtIO Audio Device"))])
        #expect(
            GuestAudioStatus(reply)
                == GuestAudioStatus(device: "XCB VirtIO Audio Device", running: nil, rate: 0, state: "on"))
    }

    @Test func aGuestWithNoCardSaysSo() {
        #expect(GuestAudioStatus(.map([("running", .bool(false))]))?.device == nil)
        #expect(GuestAudioStatus(.map([])) == nil)
    }
}
