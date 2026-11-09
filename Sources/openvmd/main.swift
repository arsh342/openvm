// openvmd — the headless host: the same library the app hosts, with no windows.
// Used by the smokes and for CLI-only use. See docs/daemon-protocol.md.
import Foundation
import OpenVMHost

// A helper job (a child of some host) runs and exits instead of hosting.
OpenVMHost.runJobCommandIfRequested(CommandLine.arguments)

do {
    try OpenVMHost.start()
} catch {
    let pid = OpenVMHost.holderPid(of: error)
    FileHandle.standardError.write(
        Data("openvmd: \(pid.map { "another openVM host (pid \($0)) is already running" } ?? OpenVMHost.startFailure(error))\n".utf8))
    exit(1)
}
RunLoop.main.run()  // keeps the main dispatch queue alive for the boot path; never returns
