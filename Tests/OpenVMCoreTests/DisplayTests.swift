// Tests for display mode and scale rules.
import Testing

@testable import OpenVMCore

@Suite struct DisplayTests {
    @Test func scalesAreWhole() {
        #expect(GuestDisplay.validScale(1) && GuestDisplay.validScale(2) && GuestDisplay.validScale(3))
        #expect(!GuestDisplay.validScale(0) && !GuestDisplay.validScale(4))
    }

    @Test func heldScaleIsReadFromTheReply() {
        #expect(GuestDisplay.heldScale(.map([("scale", .uint(2))])) == 2)
        #expect(GuestDisplay.heldScale(.map([("width", .uint(1600))])) == nil)
    }

    @Test func modeBounds() {
        #expect(GuestDisplay.validMode(width: 1920, height: 1080))
        #expect(GuestDisplay.validMode(width: 640, height: 480))
        #expect(GuestDisplay.validMode(width: 7680, height: 4320))
        #expect(!GuestDisplay.validMode(width: 639, height: 480))
        #expect(!GuestDisplay.validMode(width: 640, height: 479))
        #expect(!GuestDisplay.validMode(width: 7681, height: 1080))
    }

    @Test func heldMode() {
        let reply = CBOR.map([("width", .uint(1600)), ("height", .uint(900))])
        #expect(GuestDisplay.heldMode(reply)?.width == 1600)
        #expect(GuestDisplay.heldMode(reply)?.height == 900)
        #expect(GuestDisplay.heldMode(.map([("width", .uint(1600))])) == nil)
    }
}
