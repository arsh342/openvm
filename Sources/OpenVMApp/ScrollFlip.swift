// ScrollFlip — reverses scrolling on its way into a guest. Reported on both Linux and Windows guests:
// scrolling inside the window ran the opposite way to the Mac's. It is done on the event before the
// view sees it, so it needs nothing from the guest. View ▸ Reverse Scrolling turns it off.
import AppKit
import CoreGraphics

enum ScrollFlip {
    private static let key = "reverse-guest-scrolling"

    static let fields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2,
    ]

    static func isReversed(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    static func setReversed(_ reversed: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(reversed, forKey: key)
    }

    /// A copy of a scroll event going the other way.
    static func flipped(_ event: CGEvent) -> CGEvent? {
        guard let copy = event.copy() else { return nil }
        for field in fields {
            copy.setIntegerValueField(field, value: -event.getIntegerValueField(field))
            copy.setDoubleValueField(field, value: -event.getDoubleValueField(field))
        }
        return copy
    }

    static func flipped(_ event: NSEvent) -> NSEvent? {
        event.cgEvent.flatMap { flipped($0) }.flatMap { NSEvent(cgEvent: $0) }
    }
}
