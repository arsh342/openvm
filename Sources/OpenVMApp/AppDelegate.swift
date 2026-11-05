// AppDelegate — launch: start the host, and say so plainly if it cannot start.
import AppKit
import OpenVMHost

/// What to tell a person when the host could not start. Another host on the same
/// home (the app, or the headless openvmd) is the usual reason.
func hostStartFailureMessage(_ error: Error) -> String {
    if let pid = OpenVMHost.holderPid(of: error) {
        return "Another openVM host (process \(pid)) is already running. Quit it to use the app."
    }
    return "openVM could not start: \(OpenVMHost.startFailure(error))"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.build()
        do {
            try OpenVMHost.start()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "openVM cannot start"
            alert.informativeText = hostStartFailureMessage(error)
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}
