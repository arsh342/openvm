// VmPowerOps — running a VM: start, stop, suspend and resume, and the host's sleep.
import Foundation
import OpenVMCore
import OpenVMWindows

/// The host-sleep policy: only the VMs that are running (registry state
/// `.running`) and still have a live channel take part in the handshake. A
/// guest the user suspended is left alone, and a guest without a live handle
/// (the daemon was restarted) has nothing to flush.
nonisolated func guestsForHostSleep(_ records: [VmRecord], liveUUIDs: Set<String>) -> [VmRecord] {
    records.filter { $0.state == .running && liveUUIDs.contains($0.uuid) }
}

/// The running guests with a live channel, in registry order.
@MainActor
func runningLiveGuests() -> [VmRecord] {
    let records = (try? registry.list()) ?? []
    let live = Set(records.filter { liveVMs.peek($0.uuid) != nil }.map(\.uuid))
    return guestsForHostSleep(records, liveUUIDs: live)
}

/// Ask the guest to flush and pause it. The handshake runs off the main actor:
/// the channel connect waits for a VZ callback that arrives on the main queue,
/// so blocking the main actor there would starve the exchange. A guest that
/// cannot answer is still paused — the flush only makes the guest's own files
/// consistent in time.
@MainActor
func quiesceAndPause(_ record: VmRecord, _ g: LiveGuest) async -> String? {
    do {
        try await GuestChannel.offMainActor { try GuestChannel.suspend(g, timeoutSeconds: 5) }
    } catch {
        note("openvmd: \(record.name): guest flush skipped: \(error)")
    }
    do {
        try await g.vm.pause()
        guard g.vm.state == .paused else { return "guest did not report a paused state" }
    } catch {
        return "guest suspend failed: \(error)"
    }
    return nil
}

/// Before the host sleeps: flush and pause the running guests. The registry
/// keeps the records in `.running` — the guest is paused, not suspended by the
/// user, and it is resumed after the wake.
@MainActor
func quiesceForHostSleep() async {
    for record in runningLiveGuests() {
        guard let g = liveVMs.peek(record.uuid) else { continue }
        if let message = await quiesceAndPause(record, g) {
            note("openvmd: \(record.name): \(message)")
        }
    }
}

/// After the wake: run the guests again and re-establish the channel-side
/// state (the clock, the timezone and the shared folders).
@MainActor
func restoreAfterHostWake() async {
    for record in runningLiveGuests() {
        guard let g = liveVMs.peek(record.uuid) else { continue }
        do {
            try await g.vm.resume()
        } catch {
            note("openvmd: \(record.name): guest resume failed: \(error)")
            continue
        }
        await GuestBoot.syncClock(g, timezone: record.timezone)
        // remountShares blocks on the guest channel, so it must not hold the
        // main actor.
        await Task.detached {
            remountShares(record)
            reapplyDisplay(record)
        }.value
    }
}

nonisolated func startVm(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    guard record.state == .stopped else {
        return r.fail("start requires a stopped VM (state=\(record.state.rawValue))")
    }
    // For Windows VMs, we don't need Linux artifacts; the EFI boot loader handles it.
    if record.bootMode != .windows {
        guard GuestBoot.supportArtifacts() != nil else {
            // No guest bits: keep the registry-only transition so plain
            // lifecycle use works without artifacts installed.
            _ = try registry.start(record.uuid)
            return r.ok([
                ("message", .text("started \(record.name) (no guest: run tools/build/fetch-linux.sh)"))
            ])
        }
    }
    var artifactToken: String?
    // Netboot fetches the pinned modloop from here, with or without a disk.
    if record.bootMode != .windows, GuestBoot.pinnedModloop() != nil {
        try artifactReceiver.start()
    }
    if let diskPath = record.diskPath, record.bootMode != .windows {
        let diskURL = URL(fileURLWithPath: diskPath)
        let installRecord = diskURL.appendingPathExtension("openvm-installed")
        if !FileManager.default.fileExists(atPath: installRecord.path) {
            try artifactReceiver.start()
            artifactToken = artifactReceiver.issueToken(for: record.uuid)
        }
    }
    // Boot first, registry transition second: a failure (or a daemon kill)
    // mid-boot leaves a clean `stopped` record. Other clients do see `stopped`
    // while the boot runs; the row's `activity` ("start") says what is happening.
    // Windows: one machine identifier for the VM's lifetime.
    var machineIdentifier: Data?
    if record.bootMode == .windows {
        if let stored = record.machineIdentifier, let data = Data(base64Encoded: stored) {
            machineIdentifier = data
        } else if #available(macOS 13.0, *) {
            let fresh = GuestWindows.newMachineIdentifier()
            try registry.setMachineIdentifier(record.uuid, fresh.base64EncodedString())
            machineIdentifier = fresh
        }
    }
    let bootWait = BootWaiter()
    Task { @MainActor in
        do {
            let g = try await GuestBoot.boot(
                cpus: record.cpus, memoryMB: record.memoryMB,
                consoleURL: home.appendingPathComponent("\(record.name).console.log"),
                diskURL: record.diskPath.map { URL(fileURLWithPath: $0) },
                vmUUID: record.uuid, artifactPort: artifactPort,
                timezone: record.timezone, bootMode: record.bootMode ?? .linux,
                variableStorePath: record.variableStorePath,
                artifactToken: artifactToken, shares: record.shares ?? [],
                installMediaPath: record.installMediaPath,
                machineIdentifier: machineIdentifier)
            liveVMs.add(record.uuid, g)
            bootWait.complete("")
        } catch {
            bootWait.complete("guest boot failed: \(error)")
        }
    }
    bootWait.wait()
    if let msg = bootWait.value, !msg.isEmpty {
        return r.fail(msg)
    }
    _ = try registry.start(record.uuid)
    remountShares(record)
    return r.ok([("message", .text("started \(record.name) (guest booted)"))])
}

nonisolated func stopVm(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    if let g = liveVMs.peek(record.uuid) {
        // The framework's power button does not stop either guest, so the
        // agent starts the shutdown; requestStop below is what is left for
        // a guest with no agent. This blocks on the channel, so it runs
        // here and not on the main actor.
        var answer = GuestShutdown.AgentAnswer.none
        do {
            try GuestChannel.suspend(g, op: "shutdown")
            answer = .stopping
        } catch {
            if "\(error)".contains("refused to shut down") { answer = .refused }
            note("openvmd: \(record.name): agent could not start a shutdown: \(error)")
        }
        let grace = GuestShutdown.gracePolls(answer)
        let stopWait = BootWaiter()
        Task { @MainActor in
            do {
                try await GuestShutdown.stop(
                    isStopped: { g.vm.state == .stopped },
                    requestStop: { try g.vm.requestStop() },
                    forceStop: {
                        note("openvmd: \(record.name): no clean shutdown in time, forcing it off")
                        try await g.vm.stop()
                    },
                    gracePolls: grace)
                stopWait.complete("")
            } catch {
                stopWait.complete("guest stop failed: \(error)")
            }
        }
        stopWait.wait()
        if let msg = stopWait.value, !msg.isEmpty {
            return r.fail(msg)
        }
        if let drop = activeDrops.take(g.boot) { try? FileManager.default.removeItem(at: drop.staging) }
        _ = liveVMs.take(record.uuid)
        displayModes.clear(record.uuid)
    }
    // No live machine held (e.g. daemon restarted since boot): registry-only
    // stop. A guest orphaned by a daemon crash dies with the process.
    _ = try registry.stop(record.uuid)
    return r.ok([("message", .text("stopped \(record.name)"))])
}

nonisolated func suspendVm(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    guard record.state == .running else {
        return r.fail("suspend requires a running VM (state=\(record.state.rawValue))")
    }
    let g = try r.liveGuest(record)
    let suspendWait = BootWaiter()
    Task { @MainActor in
        // The guest flushes before it is paused: the same handshake the
        // host sleep uses.
        suspendWait.complete(await quiesceAndPause(record, g) ?? "")
    }
    suspendWait.wait()
    if let msg = suspendWait.value, !msg.isEmpty {
        return r.fail(msg)
    }
    _ = try registry.suspend(record.uuid)
    return r.ok([("message", .text("suspended \(record.name)"))])
}

nonisolated func resumeVm(_ r: VmRequest) throws -> Envelope {
    let record = try r.record()
    guard record.state == .suspended else {
        return r.fail("resume requires a suspended VM (state=\(record.state.rawValue))")
    }
    guard let g = liveVMs.peek(record.uuid) else {
        return r.fail(
            "no live channel for \(record.name) (was the daemon restarted? a suspended guest cannot outlive its daemon; stop it instead)"
        )
    }
    let resumeWait = BootWaiter()
    Task { @MainActor in
        do {
            try await g.vm.resume()
            guard g.vm.state == .running else {
                resumeWait.complete("guest did not report a running state after resume")
                return
            }
            // resume-side clock re-sync; best-effort like the boot path
            await GuestBoot.syncClock(g, timezone: record.timezone)
            resumeWait.complete("")
        } catch {
            resumeWait.complete("guest resume failed: \(error)")
        }
    }
    resumeWait.wait()
    if let msg = resumeWait.value, !msg.isEmpty {
        return r.fail(msg)
    }
    _ = try registry.resume(record.uuid)
    remountShares(record)
    reapplyDisplay(record)
    return r.ok([("message", .text("resumed \(record.name)"))])
}
