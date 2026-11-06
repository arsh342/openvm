// How a window's size becomes a guest display mode.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct DisplayFitTests {
    @Test func retinaWindowMapsToPixels() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 1000, height: 700), backingScale: 2)
        #expect(mode == DisplayFit.Mode(width: 2000, height: 1400, scale: 2))
    }

    @Test func scaleOneOnPlainDisplay() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 1280, height: 720), backingScale: 1)
        #expect(mode == DisplayFit.Mode(width: 1280, height: 720, scale: 1))
    }

    @Test func tinyWindowClampsToMinimum() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 100, height: 100), backingScale: 1)
        #expect(mode == DisplayFit.Mode(width: 640, height: 480, scale: 1))
    }

    @Test func hugeWindowClampsToMaximum() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 5000, height: 3000), backingScale: 2)
        #expect(mode.width == 7680 && mode.height == 4320)
        #expect(GuestDisplay.validMode(width: mode.width, height: mode.height))
    }

    @Test func oddBackingScalesStayInRange() {
        #expect(DisplayFit.mode(pointSize: CGSize(width: 800, height: 600), backingScale: 0.5).scale == 1)
        #expect(DisplayFit.mode(pointSize: CGSize(width: 800, height: 600), backingScale: 1.5).scale == 2)
        #expect(DisplayFit.mode(pointSize: CGSize(width: 800, height: 600), backingScale: 4).scale == 3)
        #expect(DisplayFit.mode(pointSize: CGSize(width: 800, height: 600), backingScale: 0).scale == 1)
    }

    @Test func nonsenseSizesAreClampedNotCrashed() {
        for size in [CGSize(width: -5, height: 10), CGSize(width: .nan, height: 400), CGSize(width: .infinity, height: .infinity)] {
            let mode = DisplayFit.mode(pointSize: size, backingScale: 2)
            #expect(GuestDisplay.validMode(width: mode.width, height: mode.height))
        }
    }

    @Test func scalesStepDown() {
        #expect(DisplayFit.scalesToTry(3) == [3, 2, 1])
        #expect(DisplayFit.scalesToTry(2) == [2, 1])
        #expect(DisplayFit.scalesToTry(1) == [1])
        #expect(DisplayFit.scalesToTry(9) == [3, 2, 1])
        #expect(DisplayFit.scalesToTry(0) == [1])
    }

    /// Only a refused scale steps down. A guest that cannot be reached must fail once,
    /// not three times at 30 seconds each.
    @Test func onlyAScaleRefusalStepsDown() {
        #expect(DisplayFit.shouldStepDown(after: "Windows allows at most 100% at this size"))
        #expect(DisplayFit.shouldStepDown(after: "Windows refused the scale (code 5)"))
        #expect(DisplayFit.shouldStepDown(after: "guest did not take scale 2"))
        #expect(!DisplayFit.shouldStepDown(after: "channel connect timed out"))
        #expect(!DisplayFit.shouldStepDown(after: "w is still booting; wait for it to start"))
        #expect(!DisplayFit.shouldStepDown(after: "display needs a width of 640-7680 and a height of 480-4320"))
    }
}

extension DisplayFitTests {
    /// Measured: asked for 2940 wide, the guest's X server held 2936, and the host rejects
    /// a mode that differs from the one it asked for. So only multiples of 8 are asked for.
    @Test func widthIsAMultipleOfEightSoTheGuestCanHoldIt() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 1470, height: 815), backingScale: 2)
        #expect(mode.width == 2936)  // 2940 rounded down
        #expect(mode.height == 1630)  // height is left exact
        for width in stride(from: 640, through: 1700, by: 7) {
            let m = DisplayFit.mode(pointSize: CGSize(width: CGFloat(width), height: 600), backingScale: 2)
            #expect(m.width % 8 == 0, "\(width)")
            #expect(GuestDisplay.validMode(width: m.width, height: m.height), "\(width)")
        }
    }

    @Test func roundingNeverGoesBelowTheMinimum() {
        let mode = DisplayFit.mode(pointSize: CGSize(width: 321, height: 241), backingScale: 2)  // 642 x 482
        #expect(mode.width == 640)
        #expect(mode.width >= 640)
    }
}

/// A Windows guest's picture is only right at 1024 pixels wide (measured), so its width is held there
/// and the height keeps the window's shape.
@Suite struct WindowsDisplayFitTests {
    @Test func theWidthIsHeldAndTheHeightKeepsTheWindowsShape() {
        let mode = DisplayFit.windowsMode(pointSize: CGSize(width: 1248, height: 748))
        #expect(mode == DisplayFit.Mode(width: 1024, height: 614, scale: 1))
    }

    @Test func fullScreenShapesWork() {
        #expect(DisplayFit.windowsMode(pointSize: CGSize(width: 1512, height: 982)).height == 665)
        #expect(DisplayFit.windowsMode(pointSize: CGSize(width: 1600, height: 900)).height == 576)
    }

    @Test func everyResultIsAModeTheAgentsAccept() {
        for size in [CGSize(width: 320, height: 240), CGSize(width: 4000, height: 300), CGSize(width: 300, height: 4000), CGSize(width: 0, height: 0)] {
            let mode = DisplayFit.windowsMode(pointSize: size)
            #expect(mode.width == 1024)
            #expect(GuestDisplay.validMode(width: mode.width, height: mode.height), "\(size)")
        }
    }
}
