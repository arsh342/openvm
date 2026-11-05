// openvmd — the daemon. One client at a time on a Unix socket (OVMC frames + CBOR
// v1, see docs/daemon-protocol.md and docs/guest-protocol.md). Ops: hello, echo, and the
// VM lifecycle against `VmRegistry` (vms.json).
//
// `start` boots a real guest under Virtualization.framework (GuestBoot.swift); `stop`
// brings a live guest down. Without guest artifacts, Linux ops touch only the registry.
//
// Threading: a boot needs the main dispatch queue (measured:
// anything else hits `_dispatch_assert_queue_fail`), so the blocking accept loop
// runs on a detached thread while the main thread owns the runloop. Ops that
// touch the VM hop onto the MainActor over a semaphore (BootWaiter).
import Foundation
import OpenVMCore
import OpenVMWindows

let home =
    ProcessInfo.processInfo.environment["OPENVM_HOME"].map {
        URL(fileURLWithPath: $0)
    } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm")
let sockPath = home.appendingPathComponent("openvmd.sock").path
let registry = VmRegistry()
let liveVMs = LiveVMs()
let artifactPort = UInt16(ProcessInfo.processInfo.environment["OPENVM_ARTIFACT_PORT"] ?? "8124") ?? 8124
let artifactReceiver = ArtifactReceiver(registry: registry, port: artifactPort)

let listenFd = try UnixSocket.bindListen(path: sockPath)
print("openvmd: listening on \(sockPath)")

Thread.detachNewThread { listenerLoop(fd: listenFd) }

// The host's sleep must not leave the guests running against a host that is
// going away: they are flushed and paused before the sleep, and resumed after
// the wake.
if HostPower.start(onEvent: { event in
    switch event {
    case .willSleep: await quiesceForHostSleep()
    case .didWake: await restoreAfterHostWake()
    }
}) {
    note("openvmd: host power watcher registered")
} else {
    note("openvmd: host power watcher unavailable (no sleep handshake)")
}
clearDropStaging()
PrinterBridge(home: home).start()
RunLoop.main.run()  // keeps the main dispatch queue alive for the boot path; never returns
