// A guest's scrolling ran the opposite way to the Mac's, so the window can reverse it.
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import OpenVMApp

struct ScrollFlipTests {
    private func event(_ vertical: Int32, _ horizontal: Int32) -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)!
    }

    @Test func everyDeltaIsReversed() throws {
        let original = event(10, -4)
        let flipped = try #require(ScrollFlip.flipped(original))
        for field in ScrollFlip.fields {
            #expect(flipped.getIntegerValueField(field) == -original.getIntegerValueField(field), "\(field)")
            #expect(flipped.getDoubleValueField(field) == -original.getDoubleValueField(field), "\(field)")
        }
        #expect(flipped.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) != 0)  // not a test of zeros
    }

    @Test func theOriginalIsLeftAlone() throws {
        let original = event(10, 0)
        let before = original.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        _ = ScrollFlip.flipped(original)
        #expect(original.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == before)
    }

    @Test func reversedIsTheDefaultAndCanBeTurnedOff() {
        let name = "openvm-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        #expect(ScrollFlip.isReversed(defaults))
        ScrollFlip.setReversed(false, defaults)
        #expect(!ScrollFlip.isReversed(defaults))
        defaults.removePersistentDomain(forName: name)
    }
}
