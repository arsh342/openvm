// openVM — the app. It hosts the VMs itself (OpenVMHost), because a VM window needs
// the live VZVirtualMachine in its own process, and it still serves the socket, so
// openvmctl keeps working.
import AppKit
import OpenVMHost

// A helper job (a child of some host) runs and exits: no window, no Dock icon, no host.
OpenVMHost.runJobCommandIfRequested(CommandLine.arguments)

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
