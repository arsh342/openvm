// DisplayFit — how a window's size becomes a guest display mode.
import Foundation

public nonisolated enum DisplayFit {
    /// A guest display mode: pixels, and the scale the guest's interface uses.
    public struct Mode: Equatable, Sendable {
        public let width: UInt64
        public let height: UInt64
        public let scale: UInt64

        public init(width: UInt64, height: UInt64, scale: UInt64) {
            self.width = width
            self.height = height
            self.scale = scale
        }
    }

    /// The mode that makes the guest's desktop exactly as large, in points, as the
    /// window: pixels are points times the display's backing scale, and the guest's
    /// scale is that same factor. Sizes outside what the agents accept are clamped
    /// (a window below 640 x 480 pixels, or past 7680 x 4320, still gets a valid mode).
    public static func mode(pointSize: CGSize, backingScale: CGFloat) -> Mode {
        let backing: CGFloat = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let scale = UInt64(min(3, max(1, backing.rounded())))
        func pixels(_ points: CGFloat, _ low: UInt64, _ high: UInt64) -> UInt64 {
            guard points.isFinite, points > 0 else { return low }
            let value = (points * backing).rounded()
            return UInt64(min(max(value, CGFloat(low)), CGFloat(high)))
        }
        return Mode(
            width: pixels(pointSize.width, 640, 7680), height: pixels(pointSize.height, 480, 4320),
            scale: scale)
    }

    /// The scales to try, highest first. Windows caps the scale by desktop size, so a
    /// small window may not get the one its display asks for; the highest it allows wins.
    public static func scalesToTry(_ asked: UInt64) -> [UInt64] {
        let top = min(3, max(1, asked))
        return (1...top).reversed().map { $0 }
    }

    /// Whether a refusal means "that scale does not fit", so the next lower one is worth
    /// trying. Anything else (an unreachable guest, a bad size) fails once.
    public static func shouldStepDown(after message: String) -> Bool {
        let text = message.lowercased()
        return ["allows at most", "refused the scale", "did not take scale", "monitor stayed at"]
            .contains { text.contains($0) }
    }
}
