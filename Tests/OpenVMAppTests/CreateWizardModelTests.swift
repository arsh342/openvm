// The creation wizard: what each page needs before it lets you on, what a run does to the host, and
// above all what it cleans up when it is cancelled or fails.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

/// Lets one task wait until another says go: how a blocked `start` is held until `stop` arrives.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
struct CreateWizardModelTests {
    private func hostInfo(
        linuxReady: Bool = true, wimlib: Bool = true, freeMB: UInt64 = 500_000
    ) -> [(key: String, value: CBOR)] {
        [
            ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(freeMB)),
            ("linuxReady", .bool(linuxReady)), ("hostWimlib", .bool(wimlib)),
        ]
    }

    private func wizard(
        host: FakeTransport = FakeTransport(), info: [(key: String, value: CBOR)]? = nil, existing: [String] = [],
        opened: OpenedBox = OpenedBox(), cancelWait: Duration = .seconds(60)
    ) async -> (CreateWizardModel, FakeTransport) {
        host.respond("host-info", with: info ?? hostInfo())
        let model = CreateWizardModel(
            transport: host, existingNames: existing, pollInterval: .milliseconds(1), cancelWait: cancelWait
        ) { name in opened.names.append(name) }
        await model.load()
        return (model, host)
    }

    /// Goes through the pages the way a person would, to the summary.
    private func toSummary(_ model: CreateWizardModel) async {
        model.os = .linux
        model.next()  // source
        model.next()  // resources
        model.next()  // summary
    }

    // MARK: pages

    @Test func pagesFollowTheOsChoice() async {
        let (model, _) = await wizard()
        #expect(model.page == .os)
        model.os = .linux
        model.next()
        #expect(model.page == .source)
        model.next()
        #expect(model.page == .resources)
        model.next()
        #expect(model.page == .summary)
        model.back()
        #expect(model.page == .resources)
        model.back()
        model.back()
        #expect(model.page == .os)
        model.back()
        #expect(model.page == .os)  // nowhere to go back to
    }

    @Test func defaultsFollowTheOs() async {
        let (model, _) = await wizard()
        model.os = .linux
        #expect((model.cpus, model.memoryMB, model.diskGB) == (4, 4096, 32))
        model.os = .windows
        #expect((model.cpus, model.memoryMB, model.diskGB) == (4, 8192, 64))
        #expect(model.name == "windows-11")
        model.os = .linux
        #expect(model.name == "linux")
    }

    @Test func aDefaultNameThatIsTakenGetsASuffix() async {
        let (model, _) = await wizard(existing: ["linux", "linux-2"])
        model.os = .linux
        #expect(model.name == "linux-3")
    }

    @Test func badNameBlocksNext() async {
        let (model, _) = await wizard()
        model.os = .linux
        model.next()
        model.next()  // resources
        for bad in ["", "bad name", "-x", "a/b", String(repeating: "a", count: 65), "é"] {
            model.name = bad
            #expect(model.problem != nil, "\(bad.debugDescription)")
            model.next()
            #expect(model.page == .resources, "\(bad.debugDescription) let the wizard on")
        }
        model.name = "good_name-1"
        #expect(model.problem == nil)
    }

    @Test func duplicateNameBlocksNext() async {
        let (model, _) = await wizard(existing: ["lab"])
        model.os = .linux
        model.next()
        model.next()
        model.name = "lab"
        #expect(model.problem?.contains("already exists") == true)
    }

    @Test func lowDiskBlocksNext() async {
        let usable = FakeTransport()
        usable.respond("windows-iso-check", with: [("usable", .bool(true))])
        let (windows, _) = await wizard(host: usable, info: hostInfo(freeMB: 30 * 1024))  // media 22 GB + install 20 GB needed
        windows.os = .windows
        windows.next()
        await windows.chooseISO("/x/Win.iso")  // the fake answers with no verdict, so script one

        windows.next()
        #expect(windows.page == .resources)
        #expect(windows.problem?.contains("GB") == true)
        let (linux, _) = await wizard(info: hostInfo(freeMB: 30 * 1024))  // plenty for Linux
        linux.os = .linux
        linux.next()
        linux.next()
        #expect(linux.problem == nil)
    }

    @Test func resourcesStayWithinWhatTheMacAllows() async {
        let (model, _) = await wizard()
        model.os = .linux
        model.next()
        model.next()
        model.cpus = 64
        #expect(model.problem?.contains("8") == true)
        model.cpus = 4
        model.memoryMB = 65536
        #expect(model.problem?.contains("16384") == true)
        model.memoryMB = 4096
        model.diskGB = 1
        #expect(model.problem != nil)  // too small for a Linux install
        model.diskGB = 32
        #expect(model.problem == nil)
    }

    // MARK: the source page

    @Test func x64IsoStaysOnTheSourcePage() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [
            ("usable", .bool(false)), ("problem", .text("This is not a Windows 11 ARM64 ISO."))
        ])
        let (model, _) = await wizard(host: host)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win11_x64.iso")
        #expect(model.iso == .problem("This is not a Windows 11 ARM64 ISO."))
        #expect(model.problem == "This is not a Windows 11 ARM64 ISO.")
        model.next()
        #expect(model.page == .source)
    }

    @Test func windowsNeedsAnIsoBeforeNext() async {
        let (model, _) = await wizard()
        model.os = .windows
        model.next()
        #expect(model.problem?.contains("ISO") == true)
        model.next()
        #expect(model.page == .source)
    }

    @Test func aUsableIsoLetsTheWizardOn() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let (model, _) = await wizard(host: host)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win11_arm64.iso")
        #expect(model.iso == .usable)
        #expect(model.problem == nil)
        model.next()
        #expect(model.page == .resources)
    }

    /// With no wimlib on the Mac the helper VM builds the media, and that is an Alpine guest.
    @Test func windowsWithoutWimlibOrLinuxFilesNeedsThemFirst() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let (model, _) = await wizard(host: host, info: hostInfo(linuxReady: false, wimlib: false))
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
        #expect(model.problem?.contains("Linux") == true)
        host.respond("task-start", with: [("taskId", .text("f1"))])
        host.respond("task-status", with: [("state", .text("done")), ("progress", .text(""))])
        host.respond("host-info", with: hostInfo(linuxReady: true, wimlib: false))
        await model.fetchLinux()
        #expect(model.fetch == .done)
        #expect(model.problem == nil)
    }

    @Test func linuxNeedsItsFilesFirst() async {
        let host = FakeTransport()
        let (model, _) = await wizard(host: host, info: hostInfo(linuxReady: false))
        model.os = .linux
        model.next()
        #expect(model.problem?.contains("Download") == true)
        model.next()
        #expect(model.page == .source)
        host.respond("task-start", with: [("taskId", .text("f1"))])
        host.respond("task-status", inSequence: [
            [("state", .text("running")), ("progress", .text("50% of 16 MB"))],
            [("state", .text("done")), ("progress", .text(""))],
        ])
        host.respond("host-info", with: hostInfo(linuxReady: true))
        await model.fetchLinux()
        #expect(model.fetch == .done)
        #expect(model.problem == nil)
        model.next()
        #expect(model.page == .resources)
    }

    @Test func aFailedDownloadSaysWhy() async {
        let host = FakeTransport()
        let (model, _) = await wizard(host: host, info: hostInfo(linuxReady: false))
        model.os = .linux
        model.next()
        host.respond("task-start", with: [("taskId", .text("f1"))])
        host.respond("task-status", with: [
            ("state", .text("failed")), ("progress", .text("curl: (6) Could not resolve host")),
            ("error", .text("exited with status 1: curl: (6) Could not resolve host")),
        ])
        await model.fetchLinux()
        guard case .failed(let why) = model.fetch else {
            Issue.record("expected a failure, got \(model.fetch)")
            return
        }
        #expect(why.contains("Could not resolve host"))
        #expect(model.problem != nil)  // still cannot go on
    }

    // MARK: running

    @Test func linuxFlowCreatesAndStarts() async {
        let opened = OpenedBox()
        let (model, host) = await wizard(opened: opened)
        await toSummary(model)
        model.name = "lab"
        model.cpus = 2
        model.memoryMB = 2048
        model.diskGB = 16
        await model.create()
        #expect(model.page == .finished)
        #expect(host.arg("create", "name") == .text("lab"))
        #expect(host.arg("create", "cpus") == .uint(2))
        #expect(host.arg("create", "memoryMB") == .uint(2048))
        #expect(host.arg("create", "diskSizeMB") == .uint(16 * 1024))
        #expect(host.arg("create", "boot-mode") == nil)  // Linux is the default
        #expect(host.arg("start", "id") == .text("lab"))
        #expect(host.calls.firstIndex(of: "create")! < host.calls.firstIndex(of: "start")!)
        #expect(opened.names == ["lab"])  // the window opens so the install can be watched
        #expect(model.createdName == "lab")
    }

    @Test func windowsFlowBuildsMediaThenCreatesAndStarts() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        host.respond("task-start", with: [("taskId", .text("m1")), ("output", .text("/h/media/win.raw"))])
        host.respond("task-status", inSequence: [
            [("state", .text("running")), ("progress", .text("copying install.wim"))],
            [("state", .text("done")), ("progress", .text("wrote media"))],
        ])
        let opened = OpenedBox()
        let (model, _) = await wizard(host: host, opened: opened)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win11.iso")
        model.next()
        model.name = "win"
        model.next()
        #expect(model.page == .summary)
        await model.create()
        #expect(model.page == .finished)
        let order = host.calls.filter { ["task-start", "create", "start"].contains($0) }
        #expect(order == ["task-start", "create", "start"])
        #expect(host.arg("task-start", "kind") == .text("windows-media"))
        #expect(host.arg("task-start", "iso") == .text("/Users/me/Win11.iso"))
        #expect(host.arg("task-start", "name") == .text("win"))
        #expect(host.arg("create", "boot-mode") == .text("windows"))
        #expect(host.arg("create", "install-media") == .text("/h/media/win.raw"))
        #expect(opened.names == ["win"])
    }

    @Test func theSummaryStatesTheWindowsAccount() async {
        let (model, _) = await wizard()
        model.os = .windows
        #expect(model.summaryNotes.contains { $0.contains("openvm") && $0.contains("password") })
        model.os = .linux
        #expect(!model.summaryNotes.contains { $0.contains("password") })
    }

    // MARK: cancelling

    @Test func cancelDuringMediaBuildCancelsTheTask() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        host.respond("task-start", with: [("taskId", .text("m1")), ("output", .text("/h/media/win.raw"))])
        let cancelSeen = Counter()
        let stoppedPolls = Counter()
        host.handle("task-cancel") { _ in
            _ = cancelSeen.next()
            return [("cancelled", .bool(true))]
        }
        // The script takes a moment to unmount and delete after it is told to stop.
        host.handle("task-status") { _ in
            if cancelSeen.value > 0, stoppedPolls.next() >= 3 { return [("state", .text("cancelled")), ("progress", .text(""))] }
            return [("state", .text("running")), ("progress", .text("copying"))]
        }
        let (model, _) = await wizard(host: host)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
        model.next()
        model.next()
        let run = Task { await model.create() }
        #expect(await eventually { host.calls.contains("task-status") })
        await model.cancel()
        await run.value
        #expect(host.arg("task-cancel", "taskId") == .text("m1"))
        // cancel() came back only once the task had really stopped: its cleanup (unmounting the ISO,
        // deleting a 22 GB image) takes seconds, and a new run with the same name must not meet it.
        #expect(stoppedPolls.value >= 4)
        #expect(!host.calls.contains("create"))  // nothing was made
        #expect(model.page == .os)
        #expect(!model.cancelling)
    }

    /// A task that will not stop must not hold the wizard for ever.
    @Test func cancelDoesNotWaitForeverForATaskThatWillNotStop() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        host.respond("task-start", with: [("taskId", .text("m1")), ("output", .text("/h/media/win.raw"))])
        host.respond("task-status", with: [("state", .text("running")), ("progress", .text("stuck"))])
        host.respond("task-cancel", with: [("cancelled", .bool(true))])
        let (model, _) = await wizard(host: host, cancelWait: .milliseconds(50))
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
        model.next(); model.next(); model.next()
        let run = Task { await model.create() }
        #expect(await eventually { host.calls.contains("task-status") })
        await model.cancel()  // returns after the bound, not never
        await run.value
        #expect(model.page == .os)
    }

    @Test func cancelDuringInstallRemovesTheVm() async {
        let host = FakeTransport()
        let gate = Gate()
        host.respond("create", with: [("uuid", .text("u-lab"))])
        host.handle("start") { _ in
            await gate.wait()  // the install runs until the VM is stopped
            throw HostError.remote("cancelled")
        }
        host.handle("stop") { _ in
            await gate.release()
            return [("message", .text("cancelled the start of lab"))]
        }
        host.rows = [FakeTransport.row("lab", state: "stopped")]
        host.respond("delete", with: [("message", .text("deleted lab"))])
        let (model, _) = await wizard(host: host)
        await toSummary(model)
        model.name = "lab"
        let run = Task { await model.create() }
        #expect(await eventually { host.calls.contains("start") })
        await model.cancel()
        await run.value
        let stopAt = host.calls.firstIndex(of: "stop")
        let deleteAt = host.calls.firstIndex(of: "delete")
        #expect(stopAt != nil && deleteAt != nil && stopAt! < deleteAt!)  // stopped first, then deleted
        #expect(host.arg("delete", "id") == .text("lab"))
        #expect(model.page == .os)
        #expect(model.createdName == nil)
    }

    /// `delete` answers "busy" while the cancelled `start` is still unwinding; the wizard waits and retries.
    @Test func deleteRetriesWhileTheStartUnwinds() async {
        let host = FakeTransport()
        let attempts = Counter()
        host.respond("create", with: [])
        host.handle("start") { _ in try await Task.sleep(for: .seconds(30)); return [] }
        host.respond("stop", with: [])
        host.rows = [FakeTransport.row("lab", state: "stopped")]
        host.handle("delete") { _ in
            if attempts.next() < 2 { throw HostError.remote("lab is busy: start") }
            return []
        }
        let (model, _) = await wizard(host: host)
        await toSummary(model)
        model.name = "lab"
        let run = Task { await model.create() }
        #expect(await eventually { host.calls.contains("start") })
        await model.cancel()
        run.cancel()
        #expect(attempts.value == 3)  // two busy answers, then it went through
        #expect(model.createdName == nil)
    }

    // MARK: failing

    @Test func failureKeepsTheLogTail() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        host.respond("task-start", with: [("taskId", .text("m1")), ("output", .text("/h/media/win.raw"))])
        host.respond("task-status", with: [
            ("state", .text("failed")), ("progress", .text("hdiutil: attach failed")),
            ("error", .text("exited with status 1: no space left on device | hdiutil: attach failed")),
        ])
        let (model, _) = await wizard(host: host)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
        model.next()
        model.next()
        await model.create()
        guard case .failed(let why) = model.page else {
            Issue.record("expected the failed page, got \(model.page)")
            return
        }
        #expect(why.contains("no space left on device"))  // the host's tail travels to the person
        #expect(!host.calls.contains("create"))  // a failed build made no VM
    }

    @Test func aFailedStartKeepsTheVmAndSaysWhy() async {
        let host = FakeTransport()
        host.respond("create", with: [])
        host.fail("start", with: HostError.remote("guest did not reach boot readiness; console tail:\nkernel panic"))
        let (model, _) = await wizard(host: host)
        await toSummary(model)
        model.name = "lab"
        await model.create()
        guard case .failed(let why) = model.page else {
            Issue.record("expected the failed page, got \(model.page)")
            return
        }
        #expect(why.contains("kernel panic"))
        #expect(!host.calls.contains("delete"))  // the VM stays, so it can be inspected or started again
        #expect(model.createdName == "lab")
    }

    @Test func aFailedCreateExplainsAndMakesNothing() async {
        let host = FakeTransport()
        host.fail("create", with: HostError.remote("nameExists"))
        let (model, _) = await wizard(host: host)
        await toSummary(model)
        model.name = "lab"
        await model.create()
        guard case .failed = model.page else {
            Issue.record("expected the failed page")
            return
        }
        #expect(model.createdName == nil)
        #expect(!host.calls.contains("start"))
    }

    @Test func discardRemovesTheVmAFailedStartLeft() async {
        let host = FakeTransport()
        host.respond("create", with: [])
        host.fail("start", with: HostError.remote("boom"))
        host.respond("stop", with: [])
        host.rows = [FakeTransport.row("lab", state: "stopped")]
        host.respond("delete", with: [])
        let (model, _) = await wizard(host: host)
        await toSummary(model)
        model.name = "lab"
        await model.create()
        await model.discard()
        #expect(host.calls.contains("delete"))
        #expect(model.createdName == nil)
        #expect(model.page == .os)
    }
}

/// Where the wizard says it opened a VM's window.
@MainActor
final class OpenedBox {
    var names: [String] = []
}

nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count - 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
