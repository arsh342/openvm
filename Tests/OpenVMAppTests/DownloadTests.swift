// Downloads in the app: the wizard following one the host runs, what the progress line says, the
// installer list, and quitting with one in flight.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct DownloadTextTests {
    @Test func progressSaysSizeSpeedAndTimeLeft() {
        let line = DownloadText.progress(
            done: 1_200_000_000, total: 3_900_000_000, bytesPerSecond: 12_000_000)
        #expect(line == "1.2 GB of 3.9 GB · 12 MB per second · about 4 minutes left")
    }

    @Test func beforeTheSizeOrSpeedIsKnownItSaysWhatItCan() {
        #expect(DownloadText.progress(done: 5_000_000, total: nil, bytesPerSecond: 0) == "5 MB")
        #expect(
            DownloadText.progress(done: 5_000_000, total: 100_000_000, bytesPerSecond: 0) == "5 MB of 100 MB")
        #expect(DownloadText.fraction(done: 5, total: nil) == nil)
        #expect(DownloadText.fraction(done: 50, total: 100) == 0.5)
        #expect(DownloadText.fraction(done: 150, total: 100) == 1)
    }

    @Test func timeLeftIsRoundAndPlain() {
        #expect(DownloadText.remaining(seconds: 20) == "less than a minute left")
        #expect(DownloadText.remaining(seconds: 60) == "about 1 minute left")
        #expect(DownloadText.remaining(seconds: 600) == "about 10 minutes left")
        #expect(DownloadText.remaining(seconds: 7200) == "about 2 hours left")
    }
}

@MainActor
struct WizardDownloadTests {
    private let ubuntu = InstallerCatalog.entry("ubuntu-lts")!

    private func wizard() async -> (CreateWizardModel, FakeTransport) {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond("task-start", with: [("taskId", .text("iso-1"))])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        return (model, host)
    }

    private func running(_ done: UInt64) -> [(key: String, value: CBOR)] {
        [
            ("state", .text("running")), ("bytesDone", .uint(done)), ("bytesTotal", .uint(4000)),
            ("bytesPerSecond", .uint(100)),
        ]
    }

    /// The tile starts the host's download by catalog entry, never by address, and the wizard goes on to
    /// the sizes while it runs.
    @Test func aTileStartsTheHostsDownloadAndTheWizardGoesOn() async {
        let (model, host) = await wizard()
        let path = "/Users/me/.openvm/isos/ubuntu-lts-ubuntu-26.04.1-desktop-arm64.iso"
        host.respond(
            "task-status",
            inSequence: [
                running(1000), running(3000),
                [("state", .text("done")), ("bytesDone", .uint(4000)), ("path", .text(path))],
            ])
        await model.chooseDownload(ubuntu)
        #expect(host.arg("task-start", "kind") == .text("fetch-iso"))
        #expect(host.arg("task-start", "entry") == .text("ubuntu-lts"))
        #expect(host.requests.first { $0.op == "task-start" }?.args.count == 2)  // an entry, and nothing else
        #expect(model.page == .resources)
        #expect(model.os == .linuxISO)
        #expect(model.download?.state == .verified)
        #expect(model.isoPath == path)
        #expect(model.createBlocked == nil)
        #expect(model.systemName == "Ubuntu")
    }

    /// Create stays off until the file is verified: the name and sizes can be filled in meanwhile.
    @Test func createWaitsForTheVerifiedFile() async {
        let (model, host) = await wizard()
        host.respond("task-status", with: running(1000))
        let following = Task { await model.chooseDownload(ubuntu) }
        for _ in 0..<200 where model.download?.done != 1000 { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(model.download?.state == .running)
        #expect(model.download?.total == 4000)
        #expect(model.createBlocked == "Waiting for Ubuntu to finish downloading.")
        model.next()  // the sizes are fine, so the summary is reachable
        #expect(model.page == .summary)
        await model.create()
        #expect(!host.calls.contains("create"))  // not without the file

        // Pausing stops the host's task; what it has is kept.
        await model.pauseDownload()
        await following.value
        #expect(host.arg("task-cancel", "taskId") == .text("iso-1"))
        #expect(model.download?.state == .paused)
        #expect(model.createBlocked == "The download of Ubuntu is paused.")
    }

    @Test func aDamagedDownloadSaysSoInPlainWordsAndCanBeTriedAgain() async {
        let (model, host) = await wizard()
        host.respond(
            "task-status",
            with: [
                ("state", .text("failed")), ("code", .text("download-damaged")),
                ("error", .text("expected SHA-256 aa, got bb")),
            ])
        await model.chooseDownload(ubuntu)
        guard case .failed(let failure)? = model.download?.state else {
            Issue.record("expected a failed download")
            return
        }
        #expect(failure.title == "The download was damaged")
        #expect(failure.action == .downloadAgain)
        #expect(failure.details == "expected SHA-256 aa, got bb")
        #expect(model.createBlocked != nil)

        let path = "/x/isos/ubuntu-lts-a.iso"
        host.respond("task-status", with: [("state", .text("done")), ("path", .text(path))])
        await model.startDownload()
        #expect(model.download?.state == .verified)
        #expect(model.isoPath == path)
    }

    /// When the vendor's file cannot be found, the way out is the vendor's own page.
    @Test func anInstallerThatCannotBeFoundOffersTheVendorsPage() async {
        let (model, host) = await wizard()
        host.respond(
            "task-status",
            with: [
                ("state", .text("failed")), ("code", .text("installer-not-found")), ("error", .text("404")),
            ])
        await model.chooseDownload(ubuntu)
        guard case .failed(let failure)? = model.download?.state else {
            Issue.record("expected a failed download")
            return
        }
        #expect(failure.action == .openPage(ubuntu.page))
    }

    @Test func backFromTheSizesReturnsToTheGalleryAndAFileOfYourOwnReplacesTheDownload() async {
        let (model, host) = await wizard()
        host.respond("task-status", with: [("state", .text("done")), ("path", .text("/x/a.iso"))])
        await model.chooseDownload(ubuntu)
        model.back()
        #expect(model.page == .gallery)
        host.respond("installer-identify", with: [("kind", .text("linux")), ("usable", .bool(true))])
        await model.useInstaller("/Users/me/Downloads/other.iso")
        #expect(model.download == nil)
        #expect(model.isoPath == "/Users/me/Downloads/other.iso")
        #expect(model.createBlocked == nil)
    }

    @Test func theVmIsMadeFromTheDownloadedFile() async {
        let (model, host) = await wizard()
        let path = "/Users/me/.openvm/isos/ubuntu-lts-ubuntu-26.04.1-desktop-arm64.iso"
        host.respond("task-status", with: [("state", .text("done")), ("path", .text(path))])
        await model.chooseDownload(ubuntu)
        model.next()
        await model.create()
        #expect(host.arg("create", "install-media") == .text(path))
        #expect(host.arg("create", "boot-mode") == .text("linux-iso"))
        #expect(host.arg("create", "system-name") == .text("Ubuntu"))
    }
}

@MainActor
struct InstallerListTests {
    private func row(_ entry: String, complete: Bool, taskId: String? = nil) -> CBOR {
        var fields: [(key: String, value: CBOR)] = [
            ("entry", .text(entry)), ("name", .text("Ubuntu")), ("file", .text("ubuntu.iso")),
            ("path", .text("/x/isos/\(entry)-ubuntu.iso\(complete ? "" : ".part")")), ("bytes", .uint(1000)),
            ("complete", .bool(complete)),
        ]
        if let taskId {
            fields.append(("taskId", .text(taskId)))
            fields.append(("bytesTotal", .uint(4000)))
            fields.append(("bytesPerSecond", .uint(10)))
        }
        return .map(fields)
    }

    @Test func theModelListsTheCacheAndWhatIsDownloading() async {
        let host = FakeTransport()
        host.respond(
            "installers-list",
            with: [
                (
                    "installers",
                    .array([row("a", complete: true), row("b", complete: false, taskId: "iso-9")])
                )
            ])
        let model = VMListModel(transport: host)
        await model.refresh()
        #expect(model.installers.map(\.entry) == ["a", "b"])
        #expect(model.installers.map(\.complete) == [true, false])
        #expect(model.downloading.map(\.entry) == ["b"])
        #expect(model.installers[1].bytesTotal == 4000)
    }

    /// A host from before downloads answers nothing for the op: then there are simply none.
    @Test func anOlderHostHasNoInstallers() async {
        let host = FakeTransport()
        host.fail("installers-list", with: HostError.remote("unknown op installers-list"))
        let model = VMListModel(transport: host)
        await model.refresh()
        #expect(model.installers.isEmpty)
        #expect(model.hostProblem == nil)
    }

    @Test func pauseResumeAndRemoveReachTheHostByEntry() async {
        let host = FakeTransport()
        host.respond(
            "installers-list", with: [("installers", .array([row("b", complete: false, taskId: "iso-9")]))])
        let model = VMListModel(transport: host)
        await model.refresh()
        await model.pauseDownload(model.installers[0])
        #expect(host.arg("task-cancel", "taskId") == .text("iso-9"))
        await model.startDownload(entry: "b")
        #expect(host.arg("task-start", "entry") == .text("b"))
        #expect(host.arg("task-start", "kind") == .text("fetch-iso"))
        await model.removeInstaller(entry: "b")
        #expect(host.arg("installer-remove", "entry") == .text("b"))
    }

    /// The host refuses to remove an installer a VM still starts from, and the library says why.
    @Test func aRefusedRemovalIsShown() async {
        let host = FakeTransport()
        host.fail("installer-remove", with: HostError.remote("linux-vm still starts from this installer"))
        let model = VMListModel(transport: host)
        await model.removeInstaller(entry: "b")
        #expect(model.lastError?.contains("still starts from this installer") == true)
    }
}

/// A tile chosen in the wizard's own gallery: the one place every tile click goes through, so the view
/// cannot send a download tile to the file page (it did, until 2026-11-13: the tile asked for a file).
@MainActor
struct WizardTileTests {
    private func wizard() async -> (CreateWizardModel, FakeTransport) {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond("task-start", with: [("taskId", .text("iso-1"))])
        host.respond("task-status", with: [("state", .text("done")), ("path", .text("/x/isos/a.iso"))])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        return (model, host)
    }

    @Test func aLinuxTileDownloadsAndNeverAsksForAFile() async {
        for id in ["ubuntu-lts", "fedora-workstation"] {
            let (model, host) = await wizard()
            await model.choose(InstallerCatalog.entry(id)!)
            #expect(host.arg("task-start", "entry") == .text(id), "\(id)")
            #expect(model.page == .resources, "\(id)")  // not the file page
            #expect(model.download?.entry.id == id, "\(id)")
        }
    }

    @Test func theWindowsTileOpensItsPageAndDownloadsNothing() async {
        let (model, host) = await wizard()
        await model.choose(InstallerCatalog.entry("windows-11")!)
        #expect(model.page == .source)
        #expect(model.os == .windows)
        #expect(!host.calls.contains("task-start"))
    }

    /// Every system the catalog can download goes the download way.
    @Test func everyDownloadableEntryIsDownloaded() async {
        for entry in InstallerCatalog.entries where entry.kind == .linux {
            let (model, _) = await wizard()
            await model.choose(entry)
            #expect(model.download != nil, "\(entry.id)")
        }
    }
}

/// A download as the gallery's card shows it, from the library's installer list.
struct GalleryDownloadTests {
    private func row(_ entry: String, bytes: UInt64, complete: Bool, taskId: String? = nil) -> InstallerRow {
        var fields: [(key: String, value: CBOR)] = [
            ("entry", .text(entry)), ("name", .text(entry)), ("file", .text("a.iso")),
            ("path", .text("/x/\(entry)")),
            ("bytes", .uint(bytes)), ("complete", .bool(complete)),
        ]
        if let taskId {
            fields.append(("taskId", .text(taskId)))
            fields.append(("bytesTotal", .uint(4_000_000_000)))
        }
        return InstallerRow(row: .map(fields))!
    }

    @Test func aRunningDownloadSaysHowFarAndAStoppedOneSaysPaused() {
        let found = GalleryDownload.from([
            row("ubuntu-lts", bytes: 4_000_000_000, complete: true),
            row("fedora-workstation", bytes: 1_000_000_000, complete: false, taskId: "iso-1"),
            row("kali", bytes: 120_000_000, complete: false),
        ])
        #expect(found["ubuntu-lts"] == nil)  // finished: its card is as usual
        #expect(found["fedora-workstation"]?.fraction == 0.25)
        #expect(found["fedora-workstation"]?.text == "1 GB of 4 GB")
        #expect(found["kali"]?.text == "Paused at 120 MB")
    }
}

/// Cancelling the wizard stops its download. The host keeps the part, so it can be picked up again.
@MainActor
struct WizardCancelStopsDownloadTests {
    @Test func cancelStopsTheDownload() async {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond("task-start", with: [("taskId", .text("iso-7"))])
        host.respond(
            "task-status",
            with: [("state", .text("running")), ("bytesDone", .uint(10)), ("bytesTotal", .uint(100))])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        let following = Task { await model.chooseDownload(InstallerCatalog.entry("kali")!) }
        for _ in 0..<200 where model.download?.done != 10 { try? await Task.sleep(for: .milliseconds(2)) }
        await model.cancel()
        await following.value
        #expect(host.arg("task-cancel", "taskId") == .text("iso-7"))
        #expect(model.download == nil)
        #expect(model.page == .gallery)
    }

    /// A download that has already finished is left alone: there is nothing to stop.
    @Test func aFinishedDownloadIsNotTouched() async {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond("task-start", with: [("taskId", .text("iso-8"))])
        host.respond("task-status", with: [("state", .text("done")), ("path", .text("/x/a.iso"))])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        await model.chooseDownload(InstallerCatalog.entry("kali")!)
        await model.cancel()
        #expect(!host.calls.contains("task-cancel"))
    }
}

/// A VM made from a downloaded installer is said by its system's name, not the cache's file name.
struct SystemNameTests {
    @Test func aDownloadedInstallerIsNamedByItsCatalogEntry() {
        let cached = OVMPaths.isos.appendingPathComponent("kali-kali-linux-2026.3-installer-arm64.iso").path
        #expect(CreateWizardModel.systemName(forFile: cached) == "Kali Linux")
        let ubuntu = OVMPaths.isos.appendingPathComponent("ubuntu-lts-ubuntu-26.04.1-desktop-arm64.iso").path
        #expect(CreateWizardModel.systemName(forFile: ubuntu) == "Ubuntu")
        // A file of the person's own keeps its name, wherever it is.
        #expect(
            CreateWizardModel.systemName(forFile: "/Users/me/Downloads/kali-linux-2026.3-installer-arm64.iso")
                == "kali-linux-2026.3-installer-arm64")
    }
}
