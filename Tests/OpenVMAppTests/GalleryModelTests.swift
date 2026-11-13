// The gallery: which systems it lists, when a tile is off, and which dropped file it takes.
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

struct GalleryModelTests {
    private func entry(_ id: String, kind: InstallerCatalog.Kind, evidence: String?, neededGB: Int = 24)
        -> InstallerCatalog.Entry
    {
        InstallerCatalog.Entry(
            id: id, name: id, purpose: "p", kind: kind,
            source: kind == .windows ? .page : .ubuntu(release: "26.04"),
            downloadGB: 3.9, neededGB: neededGB, time: "About 20 minutes", limits: ["l"], evidence: evidence,
            page: URL(string: "https://example.org")!, symbol: "circle")
    }

    private var entries: [InstallerCatalog.Entry] {
        [
            entry("tested", kind: .linux, evidence: "linux-iso-ubuntu.md"),
            entry("untested", kind: .linux, evidence: nil),
            entry("windows", kind: .windows, evidence: "w.txt", neededGB: 42),
        ]
    }

    private func ids(free: UInt64? = 500_000, untested: Bool = false, canDownload: Bool = true) -> [String] {
        GalleryModel.tiles(entries, freeDiskMB: free, showUntested: untested, canDownload: canDownload).map(
            \.id)
    }

    /// A tile is a support promise: a Linux system is listed only once a full install is on record.
    @Test func aLinuxSystemNeedsEvidenceToBeListed() {
        #expect(ids() == ["tested", "windows"])
    }

    @Test func theUntestedSwitchListsTheRestAndMarksThem() {
        let tiles = GalleryModel.tiles(entries, freeDiskMB: 500_000, showUntested: true, canDownload: true)
        #expect(tiles.map(\.id) == ["tested", "untested", "windows"])
        #expect(tiles.map(\.untested) == [false, true, false])
    }

    /// Windows comes from Microsoft's page, so it is offered whether or not this build can download.
    @Test func withoutDownloadsOnlyWindowsIsATile() {
        #expect(ids(untested: true, canDownload: false) == ["windows"])
    }

    @Test func aTileIsOffWithTheReasonWhenTheMacLacksTheSpace() {
        let tiles = GalleryModel.tiles(entries, freeDiskMB: 30 * 1024, showUntested: false, canDownload: true)
        #expect(tiles[0].disabledReason == nil)  // needs 24 GB
        #expect(tiles[1].disabledReason == "Needs 42 GB of free space. This Mac has 30 GB.")
        // Until the host has said how much is free, nothing is refused.
        #expect(
            GalleryModel.tiles(entries, freeDiskMB: nil, showUntested: false, canDownload: true).allSatisfy {
                $0.disabledReason == nil
            })
    }

    @Test func aTileSaysItsCostUpFront() {
        let tile = GalleryModel.tiles(entries, freeDiskMB: nil, showUntested: false, canDownload: true)[0]
        #expect(tile.cost == "3.9 GB download · 24 GB free space needed · About 20 minutes")
    }

    @Test func aDropTakesTheInstallerFile() {
        let iso = URL(fileURLWithPath: "/Users/me/Downloads/Win11.ISO")
        let other = URL(fileURLWithPath: "/Users/me/notes.txt")
        #expect(GalleryModel.installerFile(in: [other, iso]) == iso)
        #expect(GalleryModel.installerFile(in: [other]) == other)  // the check then says it is not an installer
        #expect(GalleryModel.installerFile(in: [URL(string: "https://example.org/a.iso")!]) == nil)
        #expect(GalleryModel.installerFile(in: []) == nil)
    }
}

/// A file dropped or chosen in the gallery says what it is, and a usable one moves the wizard on.
@MainActor
struct WizardGalleryTests {
    private func wizard(wimlib: Bool = true, linuxReady: Bool = true) async -> (
        CreateWizardModel, FakeTransport
    ) {
        let host = FakeTransport()
        host.respond(
            "host-info",
            with: [
                ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(500_000)),
                ("linuxReady", .bool(linuxReady)), ("hostWimlib", .bool(wimlib)),
            ])
        let model = CreateWizardModel(transport: host, existingNames: [], pollInterval: .milliseconds(1))
        await model.load()
        return (model, host)
    }

    @Test func theWizardOpensOnTheGallery() async {
        let (model, _) = await wizard()
        #expect(model.page == .gallery)
        #expect(model.problem == nil)
    }

    @Test func aLinuxFileGoesStraightToTheSizes() async {
        let (model, host) = await wizard()
        host.respond("installer-identify", with: [("kind", .text("linux")), ("usable", .bool(true))])
        await model.useInstaller("/Users/me/Downloads/ubuntu-26.04.1-desktop-arm64.iso")
        #expect(
            host.arg("installer-identify", "iso")
                == .text("/Users/me/Downloads/ubuntu-26.04.1-desktop-arm64.iso"))
        #expect(model.os == .linuxISO)
        #expect(model.iso == .usable)
        #expect(model.page == .resources)
        #expect(model.systemName == "ubuntu-26.04.1-desktop-arm64")
        model.back()
        #expect(model.page == .source)  // the file is shown there, and can be changed
    }

    /// The file decides the system, whatever the wizard had in mind, and keeps its place.
    @Test func aWindowsFileMakesItAWindowsVm() async {
        let (model, host) = await wizard()
        host.respond("installer-identify", with: [("kind", .text("windows")), ("usable", .bool(true))])
        #expect(model.os == .linuxISO)
        await model.useInstaller("/Users/me/Downloads/Win11_Arm64.iso")
        #expect(model.os == .windows)
        #expect(model.isoPath == "/Users/me/Downloads/Win11_Arm64.iso")
        #expect(model.page == .resources)
        #expect(model.memoryMB == 8192)  // Windows' defaults, not Linux's
        #expect(model.systemName == "Windows 11")
    }

    /// Without wimlib or the helper files, Windows still has a download to do: the installer page offers it.
    @Test func aWindowsFileStopsAtTheInstallerPageWhileTheHelperIsMissing() async {
        let (model, host) = await wizard(wimlib: false, linuxReady: false)
        host.respond("installer-identify", with: [("kind", .text("windows")), ("usable", .bool(true))])
        await model.useInstaller("/x/Win.iso")
        #expect(model.page == .source)
        #expect(model.problem != nil)
    }

    @Test func aFileForIntelStaysOnTheGalleryWithPlainWords() async {
        let (model, host) = await wizard()
        host.respond(
            "installer-identify",
            with: [
                ("kind", .text("linux")), ("usable", .bool(false)), ("code", .text("linux-intel")),
                ("problem", .text("This ISO is for Intel and AMD PCs.")),
            ])
        await model.useInstaller("/x/kali-amd64.iso")
        #expect(model.page == .gallery)
        #expect(model.isoFailure?.title == "This file is for Intel PCs")
        #expect(model.isoFailure?.action == .chooseAnotherFile)
        #expect(model.isoFailure?.details == "This ISO is for Intel and AMD PCs.")
    }

    @Test func aHostThatCannotAnswerIsAFailureNotACrash() async {
        let (model, host) = await wizard()
        host.fail("installer-identify", with: HostError.remote("no such op"))
        await model.useInstaller("/x/a.iso")
        #expect(model.page == .gallery)
        #expect(model.isoFailure?.title == "Something went wrong")
    }

    @Test func choosingTheWindowsTileOpensItsInstallerPage() async {
        let (model, _) = await wizard()
        model.chooseSystem(.windows)
        #expect(model.os == .windows)
        #expect(model.page == .source)
        model.back()
        #expect(model.page == .gallery)
    }

    /// What the VM runs is recorded when it is made, for the library's System column.
    @Test func createSendsTheSystemName() async {
        let (model, host) = await wizard()
        host.respond("installer-identify", with: [("kind", .text("linux")), ("usable", .bool(true))])
        await model.useInstaller("/x/fedora-45.iso")
        model.next()  // summary
        await model.create()
        #expect(host.arg("create", "system-name") == .text("fedora-45"))
    }
}

@MainActor
struct StoppedCoverTests {
    /// A Linux VM whose installer is still attached stops at the installer's own "Restart now". One button
    /// then removes the installer and starts the installed system. Any other stopped VM just offers Start.
    @Test func aStoppedVmWithItsInstallerOffersToRemoveItAndStart() {
        let cover = VMStatusView()
        cover.show(.stopped, installerAttached: true, onStart: {})
        #expect(cover.offersRemoveInstaller)
        cover.show(.stopped, installerAttached: false, onStart: {})
        #expect(!cover.offersRemoveInstaller)
        cover.show(.running, installerAttached: true, onStart: {})
        #expect(!cover.offersRemoveInstaller)
    }
}

/// Which mark a system gets, on a tile and in the library.
struct SystemBrandTests {
    @Test func catalogEntriesGetTheirOwnMarks() {
        #expect(SystemBrand.of(InstallerCatalog.entry("windows-11")!) == .windows)
        #expect(SystemBrand.of(InstallerCatalog.entry("ubuntu-lts")!) == .ubuntu)
        #expect(SystemBrand.of(InstallerCatalog.entry("fedora-workstation")!) == .fedora)
    }

    private func vm(_ bootMode: String, system: String? = nil) -> VmSummary {
        var fields: [(key: String, value: CBOR)] = [
            ("name", .text("v")), ("state", .text("stopped")), ("uuid", .text("u")),
            ("bootMode", .text(bootMode)),
        ]
        if let system { fields.append(("systemName", .text(system))) }
        return VmSummary(row: .map(fields))!
    }

    /// A VM is known by its kind, and a Linux one by the name recorded when it was made: a catalog name,
    /// or the installer file's name. Anything else keeps a neutral glyph.
    @Test func aVmGetsTheMarkOfWhatItRuns() {
        #expect(SystemBrand.of(vm("windows")) == .windows)
        #expect(SystemBrand.of(vm("windows", system: "Windows 11")) == .windows)
        #expect(SystemBrand.of(vm("linux-iso", system: "Ubuntu")) == .ubuntu)
        #expect(SystemBrand.of(vm("linux-iso", system: "ubuntu-26.04.1-desktop-arm64")) == .ubuntu)
        #expect(SystemBrand.of(vm("linux-iso", system: "Fedora Workstation")) == .fedora)
        #expect(SystemBrand.of(vm("linux-iso", system: "omarchy-4.5.0-aarch64")) == .other("terminal"))
        #expect(SystemBrand.of(vm("linux-iso")) == .other("terminal"))
    }

    @Test func aShortCardSaysSizeAndTime() {
        let tile = GalleryTile(
            entry: InstallerCatalog.entry("ubuntu-lts")!, disabledReason: nil, untested: true)
        #expect(tile.shortCost == "3.9 GB · About 20 minutes")
    }
}
