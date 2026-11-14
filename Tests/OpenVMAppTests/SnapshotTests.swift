// Snapshot tests: render a view to a PNG and compare it with a recorded baseline.
//
// They are opt-in (OPENVM_UI_SNAPSHOTS=1), because how text and controls draw depends on
// the macOS version and display, so a baseline recorded on one Mac fails on another and on CI.
// Record or refresh baselines with OPENVM_UI_SNAPSHOTS=1 OPENVM_UI_RECORD=1.
import AppKit
import OpenVMCore
import SwiftUI
import Testing

@testable import OpenVMApp

enum Snapshot {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["OPENVM_UI_SNAPSHOTS"] == "1" }
    nonisolated static var recording: Bool { ProcessInfo.processInfo.environment["OPENVM_UI_RECORD"] == "1" }

    /// Renders through a real hosting view, so AppKit-backed controls (buttons, spinners)
    /// draw as they do on screen. Light appearance and a fixed size keep it repeatable.
    @MainActor
    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool = false)
        -> NSBitmapImageRep?
    {
        // The window gives the view a background and an appearance to inherit, as on screen.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Lists and tables make their rows only inside a window, and a turn of the run loop later.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func baselineURL(_ name: String, file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("Snapshots/\(name).png")
    }

    /// How many pixels differ by more than a few levels in any channel.
    static func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return nil }
        var different = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let p = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let q = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let delta = max(
                    abs(p.redComponent - q.redComponent), abs(p.greenComponent - q.greenComponent),
                    abs(p.blueComponent - q.blueComponent), abs(p.alphaComponent - q.alphaComponent))
                if delta > 0.015 { different += 1 }
            }
        }
        return different
    }

    /// Checks a view in light and in dark: `name` and `name-dark`.
    @MainActor
    static func check<V: View>(
        _ name: String, _ view: V, width: CGFloat, height: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        checkOne(name, view, width: width, height: height, dark: false, sourceLocation: sourceLocation)
        checkOne(
            "\(name)-dark", view, width: width, height: height, dark: true, sourceLocation: sourceLocation)
    }

    @MainActor
    private static func checkOne<V: View>(
        _ name: String, _ view: V, width: CGFloat, height: CGFloat, dark: Bool, sourceLocation: SourceLocation
    ) {
        guard let rep = render(view, width: width, height: height, dark: dark) else {
            Issue.record("could not render \(name)", sourceLocation: sourceLocation)
            return
        }
        let url = baselineURL(name)
        if recording {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return
        }
        guard let data = try? Data(contentsOf: url), let baseline = NSBitmapImageRep(data: data) else {
            Issue.record(
                "no baseline for \(name); record it with OPENVM_UI_RECORD=1", sourceLocation: sourceLocation)
            return
        }
        guard let different = differingPixels(rep, baseline) else {
            Issue.record(
                "\(name) is \(rep.pixelsWide)x\(rep.pixelsHigh), the baseline is \(baseline.pixelsWide)x\(baseline.pixelsHigh)",
                sourceLocation: sourceLocation)
            return
        }
        let allowed = rep.pixelsWide * rep.pixelsHigh / 500  // 0.2% for anti-aliasing noise
        #expect(
            different <= allowed, "\(name): \(different) pixels differ (allowed \(allowed))",
            sourceLocation: sourceLocation)
    }
}

@MainActor
struct SnapshotTests {
    func model(_ rows: [CBOR]) async -> VMListModel {
        let host = FakeTransport()
        host.rows = rows
        let model = VMListModel(transport: host)
        await model.refresh()
        return model
    }

    private var mixed: [CBOR] {
        [
            .map([
                ("name", .text("ubuntu-lab")), ("state", .text("running")),
                ("uuid", .text("uuid-ubuntu-lab")),
                ("cpus", .uint(4)), ("memoryMB", .uint(4096)), ("bootMode", .text("linux-iso")),
                ("systemName", .text("Ubuntu")),
            ]),
            .map([
                ("name", .text("fedora-box")), ("state", .text("stopped")),
                ("uuid", .text("uuid-fedora-box")),
                ("cpus", .uint(4)), ("memoryMB", .uint(4096)), ("bootMode", .text("linux-iso")),
                ("systemName", .text("Fedora Workstation")),
            ]),
            FakeTransport.row("windows-11", state: "suspended", bootMode: "windows"),
            FakeTransport.row("scratch", state: "stopped", bootMode: "linux-iso"),
        ]
    }

    private func nav(selecting uuid: String? = nil) -> LibraryNav {
        let nav = LibraryNav()
        nav.selection = uuid
        return nav
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryTableWithMixedStates() async {
        let model = await model(mixed)
        Snapshot.check(
            "library-table",
            VMTableView(
                model: model, nav: nav(selecting: "uuid-windows-11"), run: { _, _ in }, newVM: { _ in },
                gallery: GalleryModel(transport: FakeTransport())),
            width: 700, height: 420)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryWithNoVms() async {
        let model = await model([])
        Snapshot.check(
            "library-empty",
            VMTableView(
                model: model, nav: nav(), run: { _, _ in }, newVM: { _ in },
                gallery: GalleryModel(transport: FakeTransport())), width: 700, height: 420)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryAfterAFailedAction() async {
        let model = await model([FakeTransport.row("scratch", state: "stopped", bootMode: "linux-iso")])
        model.lastError = "scratch is busy: start"
        Snapshot.check(
            "library-error",
            VMTableView(
                model: model, nav: nav(), run: { _, _ in }, newVM: { _ in },
                gallery: GalleryModel(transport: FakeTransport())), width: 700, height: 420)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func librarySidebar() async {
        let model = await model(mixed)
        Snapshot.check(
            "library-sidebar", LibrarySidebarView(model: model, nav: nav()), width: 220, height: 420)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryDetailOfAPausedVm() async {
        let model = await model([
            FakeTransport.row("windows-11", state: "suspended", bootMode: "windows", memoryMB: 8192)
        ])
        let defaults = UserDefaults(suiteName: "openvm-snapshots")!
        defaults.removePersistentDomain(forName: "openvm-snapshots")
        Snapshot.check(
            "library-detail",
            VMDetailPane(
                model: model, nav: nav(selecting: "uuid-windows-11"),
                thumbnails: ThumbnailStore(directory: FileManager.default.temporaryDirectory),
                settings: AppSettingsModel(defaults: defaults), run: { _, _ in }),
            width: 280, height: 560)
    }

    /// A guest's picture is wider than the frame it is shown in. It must stay inside the pane.
    @Test(.enabled(if: Snapshot.enabled))
    func libraryDetailWithAWidePreview() async throws {
        let model = await model([FakeTransport.row("linux-vm", state: "stopped", bootMode: "linux-iso")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openvm-thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThumbnailStore(directory: directory)
        let wide = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: wide)
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 240).fill()  // the picture's own left and right edges
        NSRect(x: 600, y: 0, width: 40, height: 240).fill()
        NSGraphicsContext.restoreGraphicsState()
        #expect(store.save(wide, for: "uuid-linux-vm"))
        let defaults = UserDefaults(suiteName: "openvm-snapshots")!
        defaults.removePersistentDomain(forName: "openvm-snapshots")
        Snapshot.check(
            "library-detail-preview",
            VMDetailPane(
                model: model, nav: nav(selecting: "uuid-linux-vm"), thumbnails: store,
                settings: AppSettingsModel(defaults: defaults), run: { _, _ in }),
            width: 280, height: 560)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func appSettings() async {
        let defaults = UserDefaults(suiteName: "openvm-snapshots")!
        defaults.removePersistentDomain(forName: "openvm-snapshots")
        Snapshot.check(
            "app-settings", AppSettingsView(model: AppSettingsModel(defaults: defaults)), width: 480,
            height: 260)
    }
}

extension SnapshotTests {
    private func settingsModel(_ vm: VmSummary, shares: Bool = false) async -> VMSettingsModel {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        if shares {
            host.respond(
                "share-list",
                with: [
                    (
                        "shares",
                        .array([
                            .map([
                                ("hostPath", .text("/Users/me/Projects")),
                                ("guestPath", .text("/mnt/openvm/Projects")),
                            ])
                        ])
                    )
                ])
        }
        let model = VMSettingsModel(vm: vm, transport: host)
        await model.load()
        return model
    }

    @Test(.enabled(if: Snapshot.enabled))
    func settingsOfAStoppedLinuxVm() async {
        let model = await settingsModel(
            FakeTransport.summary("lab", state: "stopped", timezone: "Europe/Berlin"), shares: true)
        Snapshot.check(
            "settings-stopped-linux", VMSettingsView(model: model, close: {}), width: 520, height: 740)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func settingsOfARunningWindowsVm() async {
        let model = await settingsModel(
            FakeTransport.summary("win11", state: "running", bootMode: "windows", cpus: 4, memoryMB: 8192))
        Snapshot.check(
            "settings-running-windows", VMSettingsView(model: model, close: {}), width: 520, height: 740)
    }
}

extension SnapshotTests {
    private func wizardModel(_ host: FakeTransport = FakeTransport(), linuxReady: Bool = true) async
        -> CreateWizardModel
    {
        host.respond(
            "host-info",
            with: [
                ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(500_000)),
                ("linuxReady", .bool(linuxReady)), ("hostWimlib", .bool(false)),
            ])
        if !host.answers("linux-iso-check") {
            host.respond("linux-iso-check", with: [("usable", .bool(true))])
        }
        let model = CreateWizardModel(transport: host, existingNames: ["lab"], pollInterval: .milliseconds(1))
        await model.load()
        return model
    }

    private func wizardView(_ model: CreateWizardModel) -> CreateWizardView {
        CreateWizardView(model: model, gallery: GalleryModel(transport: FakeTransport()), close: {})
    }

    /// The wizard opens on Linux from an ISO; a person chooses one on the source page.
    private func toResources(_ model: CreateWizardModel) async {
        model.next()  // source
        await model.chooseISO("/Users/me/Downloads/ubuntu-24.04-arm64.iso")
        model.next()  // resources
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardOpensOnTheGallery() async {
        let model = await wizardModel()
        // The size of the wizard's page in its window, which cannot be resized: everything must fit.
        Snapshot.check("wizard-gallery", wizardView(model), width: 640, height: 532)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func galleryRefusesAFileForIntel() async {
        let host = FakeTransport()
        host.respond(
            "installer-identify",
            with: [
                ("kind", .text("linux")), ("usable", .bool(false)), ("code", .text("linux-intel")),
                ("problem", .text(LinuxISOCheck.Verdict.x86Only.problem ?? "")),
            ])
        let model = await wizardModel(host)
        await model.useInstaller("/Users/me/Downloads/kali-linux-amd64.iso")
        Snapshot.check("wizard-gallery-intel", wizardView(model), width: 640, height: 532)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardWhileItsInstallerDownloads() async {
        let host = FakeTransport()
        host.respond("task-start", with: [("taskId", .text("iso-1"))])
        host.respond(
            "task-status",
            with: [
                ("state", .text("running")), ("bytesDone", .uint(1_200_000_000)),
                ("bytesTotal", .uint(3_900_000_000)),
                ("bytesPerSecond", .uint(12_000_000)),
            ])
        let model = await wizardModel(host)
        let following = Task { await model.chooseDownload(InstallerCatalog.entry("ubuntu-lts")!) }
        for _ in 0..<200 where model.download?.done != 1_200_000_000 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        Snapshot.check("wizard-downloading", wizardView(model), width: 600, height: 540)
        await model.pauseDownload()
        await following.value
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryInstallers() async {
        let host = FakeTransport()
        host.respond(
            "installers-list",
            with: [
                (
                    "installers",
                    .array([
                        .map([
                            ("entry", .text("ubuntu-lts")), ("name", .text("Ubuntu")),
                            ("file", .text("ubuntu-26.04.1-desktop-arm64.iso")),
                            ("path", .text("/x/a.iso")), ("bytes", .uint(3_900_000_000)),
                            ("complete", .bool(true)),
                        ]),
                        .map([
                            ("entry", .text("fedora-workstation")), ("name", .text("Fedora Workstation")),
                            ("file", .text("Fedora-Workstation-Live-45-1.4.aarch64.iso")),
                            ("path", .text("/x/b.iso.part")),
                            ("bytes", .uint(1_200_000_000)), ("complete", .bool(false)),
                            ("taskId", .text("iso-2")),
                            ("bytesTotal", .uint(2_987_100_160)), ("bytesPerSecond", .uint(12_000_000)),
                        ]),
                    ])
                )
            ])
        let model = VMListModel(transport: host)
        await model.refresh()
        Snapshot.check(
            "library-installers", InstallersView(model: model, newVM: { _ in }), width: 700, height: 300)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardGetsWindowsFromMicrosoft() async {
        let model = await wizardModel()
        model.chooseSystem(.windows)
        Snapshot.check("wizard-windows", wizardView(model), width: 600, height: 540)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardRefusesAnX64Iso() async {
        let host = FakeTransport()
        host.respond(
            "windows-iso-check",
            with: [
                ("usable", .bool(false)),
                (
                    "problem",
                    .text(
                        "This is not a Windows 11 ARM64 ISO. A Mac with Apple Silicon needs the ARM64 edition, not the x64 one."
                    )
                ),
            ])
        let model = await wizardModel(host, linuxReady: false)
        model.os = .windows
        model.next()
        await model.chooseISO("/Users/me/Downloads/Win11_x64.iso")
        Snapshot.check("wizard-source-x64", wizardView(model), width: 600, height: 540)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardSizesTheVm() async {
        let model = await wizardModel()
        await toResources(model)
        Snapshot.check("wizard-resources", wizardView(model), width: 600, height: 540)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardWhileInstalling() async {
        let host = FakeTransport()
        host.respond("create", with: [])
        host.handle("start") { _ in
            try await Task.sleep(for: .seconds(60))
            return []
        }
        let model = await wizardModel(host)
        await toResources(model)
        model.name = "demo"
        model.next()  // summary
        let run = Task { await model.create() }
        _ = await eventually { host.calls.contains("start") }
        Snapshot.check("wizard-working", wizardView(model), width: 600, height: 540)
        run.cancel()
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardAfterAFailedStart() async {
        let host = FakeTransport()
        host.respond("create", with: [])
        host.fail(
            "start",
            with: HostError.remote(
                "guest did not reach boot readiness with a responding openvm-tools agent; console tail:\nrandom: crng init done"
            ))
        let model = await wizardModel(host)
        await toResources(model)
        model.name = "demo"
        model.next()  // summary
        await model.create()
        Snapshot.check("wizard-failed", wizardView(model), width: 600, height: 540)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func wizardSidebarOnTheResourcesStep() async {
        let wizard = CreateWizardModel(transport: FakeTransport(), existingNames: [], openWindow: { _ in })
        wizard.os = .windows
        wizard.next()
        Snapshot.check("wizard-sidebar", WizardSidebarView(model: wizard), width: 240, height: 360)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func wizardAsksForTheWindowsAccount() async {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields + [("hostWimlib", .bool(true))])
        host.respond("windows-iso-check", with: [("usable", .bool(true))])
        let model = CreateWizardModel(transport: host, existingNames: [])
        await model.load()
        model.os = .windows
        model.next()
        await model.chooseISO("/x/Win.iso")
        model.next()
        model.next()
        model.accountName = "arsh"
        Snapshot.check(
            "wizard-account",
            CreateWizardView(model: model, gallery: GalleryModel(transport: FakeTransport()), close: {}),
            width: 600, height: 540)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func wizardAsksForALinuxIso() async {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        host.respond(
            "linux-iso-check",
            with: [("usable", .bool(false)), ("problem", .text(LinuxISOCheck.Verdict.x86Only.problem ?? ""))])
        let model = CreateWizardModel(transport: host, existingNames: [])
        await model.load()
        model.os = .linuxISO
        model.next()
        await model.chooseISO("/x/kali-amd64.iso")
        Snapshot.check(
            "wizard-linux-iso",
            CreateWizardView(model: model, gallery: GalleryModel(transport: FakeTransport()), close: {}),
            width: 600, height: 540)
    }
}
