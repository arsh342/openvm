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
        if !host.answers("linux-iso-check") { host.respond("linux-iso-check", with: [("usable", .bool(true))]) }
        let model = CreateWizardModel(
            transport: host, existingNames: existing, pollInterval: .milliseconds(1), cancelWait: cancelWait
        ) { name in opened.names.append(name) }
        await model.load()
        return (model, host)
    }

    /// Linux from an ISO is the plain flow (no account page, nothing to build), so it is the one the
    /// tests of names, sizes, cancelling and failing go through.
    private func toResources(_ model: CreateWizardModel) async {
        model.os = .linuxISO
        model.next()  // source
        await model.chooseISO("/x/linux-arm64.iso")
        model.next()  // resources
    }

    /// Goes through the pages the way a person would, to the summary.
    private func toSummary(_ model: CreateWizardModel) async {
        await toResources(model)
        model.next()  // summary
    }

    // MARK: pages

    @Test func pagesFollowTheOsChoice() async {
        let (model, _) = await wizard()
        #expect(model.page == .os)
        model.os = .linuxISO
        model.next()
        #expect(model.page == .source)
        await model.chooseISO("/x/linux-arm64.iso")
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
        #expect(model.os == .linuxISO)  // what the wizard opens on
        #expect((model.cpus, model.memoryMB, model.diskGB) == (4, 4096, 64))
        #expect(model.name == "linux-vm")
        model.os = .windows
        #expect((model.cpus, model.memoryMB, model.diskGB) == (4, 8192, 64))
        #expect(model.name == "windows-11")
        model.os = .linuxISO
        #expect(model.name == "linux-vm")
    }

    @Test func aDefaultNameThatIsTakenGetsASuffix() async {
        let (model, _) = await wizard(existing: ["linux-vm", "linux-vm-2"])
        #expect(model.name == "linux-vm-3")
        model.os = .windows
        model.os = .linuxISO
        #expect(model.name == "linux-vm-3")
    }

    @Test func badNameBlocksNext() async {
        let (model, _) = await wizard()
        await toResources(model)
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
        await toResources(model)
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
        await toResources(linux)
        #expect(linux.problem == nil)
    }

    @Test func resourcesStayWithinWhatTheMacAllows() async {
        let (model, _) = await wizard()
        await toResources(model)
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

    /// With no wimlib on the Mac the helper VM builds the media, and it needs its files fetched.
    @Test func windowsWithoutWimlibOrTheHelperFilesNeedsThemFirst() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let (model, _) = await wizard(host: host, info: hostInfo(linuxReady: false, wimlib: false))
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
        #expect(model.problem?.contains("helper download") == true)
        model.next()
        #expect(model.page == .source)
        host.respond("task-start", with: [("taskId", .text("f1"))])
        host.respond("task-status", with: [("state", .text("done")), ("progress", .text(""))])
        host.respond("host-info", with: hostInfo(linuxReady: true, wimlib: false))
        await model.fetchLinux()
        #expect(model.fetch == .done)
        #expect(model.problem == nil)
    }

    @Test func aFailedDownloadSaysWhy() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let (model, _) = await wizard(host: host, info: hostInfo(linuxReady: false, wimlib: false))
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Win.iso")
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

    @Test func theIsoFlowCreatesAndStarts() async {
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
        #expect(host.arg("create", "boot-mode") == .text("linux-iso"))  // every create says which
        #expect(host.arg("create", "install-media") == .text("/x/linux-arm64.iso"))
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
        model.fillInAnAccount()
        model.next()
        #expect(model.page == .summary)
        await model.create()
        #expect(model.page == .finished)
        let order = host.calls.filter { ["task-start", "create", "start"].contains($0) }
        #expect(order == ["task-start", "create", "start"])
        #expect(host.arg("task-start", "kind") == .text("windows-media"))
        #expect(host.arg("task-start", "iso") == .text("/Users/me/Win11.iso"))
        #expect(host.arg("task-start", "name") == .text("win"))
        // The account went to the media, and the app did not keep the password after that.
        #expect(host.arg("task-start", "user") == .text("arsh"))
        #expect(host.arg("task-start", "password") == .text("a good password"))
        #expect(host.arg("task-start", "autologon") == .text("yes"))
        #expect(model.accountPassword.isEmpty && model.accountConfirm.isEmpty)
        #expect(host.arg("create", "boot-mode") == .text("windows"))
        #expect(host.arg("create", "install-media") == .text("/h/media/win.raw"))
        #expect(opened.names == ["win"])
    }

    @Test func theSummaryStatesTheWindowsAccount() async {
        let (model, _) = await wizard()
        model.os = .windows
        model.accountName = "arsh"
        #expect(model.summaryNotes.contains { $0.contains("arsh") && $0.contains("password") })
        model.os = .linuxISO
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
        model.fillInAnAccount()
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
        model.next(); model.next()
        model.fillInAnAccount()
        model.next()
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
        model.fillInAnAccount()
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

@MainActor
struct WizardAccountTests {
    private func windowsWizard() async -> (CreateWizardModel, FakeTransport) {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields + [("hostWimlib", .bool(true))])
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        model.os = .windows
        model.next()
        await model.chooseISO("/x/Win.iso")
        model.next()
        model.name = "win"
        return (model, host)
    }

    @Test func windowsAsksForAnAccountAndLinuxDoesNot() async {
        let (windows, _) = await windowsWizard()
        windows.next()
        #expect(windows.page == .account)
        windows.back()
        #expect(windows.page == .resources)
    }

    @Test func theAccountPageNeedsAGoodNameAndMatchingPasswords() async {
        let (model, _) = await windowsWizard()
        model.next()
        model.accountName = "arsh"
        #expect(model.problem != nil)  // no password yet
        model.next()
        #expect(model.page == .account)
        model.accountPassword = "secret"
        model.accountConfirm = "other"
        #expect(model.problem?.contains("match") == true)
        model.accountConfirm = "secret"
        model.accountName = "Administrator"
        #expect(model.problem != nil)
        model.accountName = "arsh"
        #expect(model.problem == nil)
        model.next()
        #expect(model.page == .summary)
        model.back()
        #expect(model.page == .account)
    }

    @Test func theSummaryNeverShowsThePassword() async {
        let (model, _) = await windowsWizard()
        model.next()
        model.accountName = "arsh"
        model.accountPassword = "hunter2"
        model.accountConfirm = "hunter2"
        model.next()
        #expect(model.summaryNotes.allSatisfy { !$0.contains("hunter2") })
        #expect(model.summaryNotes.contains { $0.contains("arsh") })
    }

    @Test func theSummarySaysWhatSigningInMeans() async {
        let (model, _) = await windowsWizard()
        model.autoLogon = false
        #expect(model.summaryNotes.contains { $0.contains("ask for the password") })
    }

    @Test func aMacNameWindowsWouldRefuseIsNotSuggested() {
        #expect(CreateWizardModel.suggestedAccountName("arsh") == "arsh")
        #expect(CreateWizardModel.suggestedAccountName("Administrator") == "user")
        #expect(CreateWizardModel.suggestedAccountName("a b") == "user")
    }
}

extension CreateWizardModel {
    /// What a person fills in on the account page.
    func fillInAnAccount() {
        accountName = "arsh"
        accountPassword = "a good password"
        accountConfirm = "a good password"
    }
}

@MainActor
struct WizardLinuxISOTests {
    private func wizard(_ reply: [(key: String, value: CBOR)]) async -> (CreateWizardModel, FakeTransport) {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond("linux-iso-check", with: reply)
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        model.os = .linuxISO
        return (model, host)
    }

    @Test func anIsoIsNeededAndNoLinuxFilesAre() async {
        let (model, host) = await wizard([("usable", .bool(true))])
        model.next()
        #expect(model.page == .source)
        #expect(model.problem?.contains("ISO") == true)
        await model.chooseISO("/x/omarchy-arm64.iso")
        #expect(host.arg("linux-iso-check", "iso") == .text("/x/omarchy-arm64.iso"))
        #expect(model.problem == nil)
    }

    @Test func anIntelIsoStopsThereWithTheReason() async {
        let (model, _) = await wizard([("usable", .bool(false)), ("problem", .text("This ISO is for Intel and AMD PCs."))])
        model.next()
        await model.chooseISO("/x/kali-amd64.iso")
        #expect(model.problem?.contains("Intel") == true)
        model.next()
        #expect(model.page == .source)
    }

    @Test func anIsoThatCannotBeReadCanStillBeTried() async {
        let (model, _) = await wizard([("usable", .bool(true)), ("unknown", .bool(true))])
        model.next()
        await model.chooseISO("/x/odd.iso")
        #expect(model.isoUnchecked)
        #expect(model.problem == nil)
    }

    @Test func itHasNoAccountStepAndCreatesFromTheIso() async {
        let (model, host) = await wizard([("usable", .bool(true))])
        model.next()
        await model.chooseISO("/x/fedora-aarch64.iso")
        model.next()
        #expect(model.page == .resources)
        #expect(model.name == "linux-vm")
        #expect(model.diskGB == 64)
        model.next()
        #expect(model.page == .summary)  // the distribution's own installer makes the account
        await model.create()
        #expect(model.page == .finished)
        #expect(host.arg("create", "boot-mode") == .text("linux-iso"))
        #expect(host.arg("create", "install-media") == .text("/x/fedora-aarch64.iso"))
        #expect(!host.calls.contains("task-start"))  // nothing to build: the ISO boots as it is
        #expect(host.calls.contains("start"))
    }

    @Test func changingTheSystemForgetsTheIso() async {
        let (model, _) = await wizard([("usable", .bool(true))])
        model.next()
        await model.chooseISO("/x/a.iso")
        model.os = .windows
        #expect(model.isoPath == nil)
        #expect(model.iso == .none)
    }

    @Test func theSummaryExplainsTheInstallerAndTheMissingTools() async {
        let (model, _) = await wizard([("usable", .bool(true))])
        #expect(model.summaryNotes.contains { $0.contains("Eject Installer ISO") })
        #expect(model.summaryNotes.contains { $0.contains("guest tools") })
        #expect(model.summaryNotes.contains { $0.contains("no sound") && $0.contains("README") })
    }
}
