// OpenVMHost — what runs VMs. The app and the headless openvmd both call start()
// and then run the main run loop themselves: Virtualization.framework needs the
// main dispatch queue, so the caller owns it.
//
// The socket (OVMC frames + CBOR v1, docs/daemon-protocol.md) is served on its own
// thread; handlers that touch a VM hop onto the main actor over a semaphore.
import Foundation
import OpenVMCore
import Virtualization

public nonisolated enum OpenVMHost {
    /// Held for the life of the process.
    nonisolated(unsafe) private static var lock: HostLock?

    /// Why a host could not start, in words for a person.
    public static func startFailure(_ error: Error) -> String { "\(error)" }

    /// The holder's pid when another host owns this home; nil when `error` is something else.
    public static func holderPid(of error: Error) -> Int32? {
        if case HostLockError.held(let pid) = error { return pid }
        return nil
    }

    /// Takes the home directory's lock, binds the socket and starts serving.
    /// The lock comes first: bindListen unlinks whatever socket file is there.
    public static func start() throws {
        lock = try HostLock.acquire(home: home)
        // We are the only host, so no guest from an earlier host survives: it died with
        // the process that ran it. Records that still claim one are stale.
        for uuid in reconcileRecords((try? registry.list()) ?? [], live: []) {
            markStopped(registry, uuid)
            note("openvmd: \(uuid) was left running by an earlier host; recorded as stopped")
        }
        let listenFd = try UnixSocket.bindListen(path: sockPath)
        note("openvmd: listening on \(sockPath)")
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
    }

    /// The blocking core of `stopAll`, also the `stop-all` op. Returns how many guests it stopped.
    nonisolated static func stopAllBlocking() -> Int {
        let before = Set(liveVMs.ids())
        for _ in 0..<5 {
            let ids = liveVMs.ids()
            if ids.isEmpty { break }
            let group = DispatchGroup()
            for id in ids {
                group.enter()
                DispatchQueue.global().async {
                    _ = vmOp("stop", [("id", .text(id))], Envelope(type: .vmRequest, correlationId: 0))
                    group.leave()
                }
            }
            group.wait()
            // A VM busy with another op answers "busy", and a cancelled boot leaves the table a
            // moment after its stop returns: give them a moment and go round again.
            if !liveVMs.ids().isEmpty { Thread.sleep(forTimeInterval: 0.5) }
        }
        return stoppedCount(before: before, after: Set(liveVMs.ids()))
    }

    /// Shuts down every guest this host holds, all at once, and returns when they are gone.
    /// The app calls this when it quits. Each stop is the same op `openvmctl stop` sends: the
    /// guest is asked to shut down and forced off only if it does not, and a guest still
    /// booting is cancelled. It runs off the main actor, because a stop waits for the main
    /// queue and would deadlock there.
    public static func stopAll() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = stopAllBlocking()
                done.resume()
            }
        }
    }

    /// The live machine for a VM, for a view to show. Main actor only.
    @MainActor
    public static func liveMachine(_ uuid: String) -> VZVirtualMachine? {
        liveVMs.peek(uuid)?.vm
    }
}
