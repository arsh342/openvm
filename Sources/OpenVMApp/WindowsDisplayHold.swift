// WindowsDisplayHold — whether a Windows guest is held at 1024 pixels wide.
//
// With the released `viogpudo`, any width but the one Windows booted with scrambles in the window
// (docs/gui-notes.md), so the app holds a Windows guest at 1024 wide. A guest whose display driver
// has the fix can take any size. Until a signed release carries it the app cannot tell, so lifting
// the hold is a per-VM choice (View ▸ Full Size Display), off unless someone turns it on.
import Foundation
import OpenVMCore

struct WindowsDisplayHold {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ uuid: String) -> String { "windows-full-size-\(uuid)" }

    func isLifted(_ uuid: String) -> Bool { defaults.bool(forKey: key(uuid)) }
    func setLifted(_ lifted: Bool, for uuid: String) { defaults.set(lifted, forKey: key(uuid)) }

    /// The mode to ask a Windows guest for: the window's full size at the display's scale when the
    /// hold is lifted, otherwise the 1024-wide stopgap.
    func mode(for uuid: String, pointSize: CGSize, backingScale: CGFloat) -> DisplayFit.Mode {
        isLifted(uuid)
            ? DisplayFit.mode(pointSize: pointSize, backingScale: backingScale)
            : DisplayFit.windowsMode(pointSize: pointSize)
    }
}
