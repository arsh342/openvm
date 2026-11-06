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
    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
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

    @MainActor
    static func check<V: View>(
        _ name: String, _ view: V, width: CGFloat, height: CGFloat, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let rep = render(view, width: width, height: height) else {
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
            Issue.record("no baseline for \(name); record it with OPENVM_UI_RECORD=1", sourceLocation: sourceLocation)
            return
        }
        guard let different = differingPixels(rep, baseline) else {
            Issue.record(
                "\(name) is \(rep.pixelsWide)x\(rep.pixelsHigh), the baseline is \(baseline.pixelsWide)x\(baseline.pixelsHigh)",
                sourceLocation: sourceLocation)
            return
        }
        let allowed = rep.pixelsWide * rep.pixelsHigh / 500  // 0.2% for anti-aliasing noise
        #expect(different <= allowed, "\(name): \(different) pixels differ (allowed \(allowed))", sourceLocation: sourceLocation)
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

    @Test(.enabled(if: Snapshot.enabled))
    func listWithMixedStates() async {
        let model = await model([
            FakeTransport.row("ubuntu-lab", state: "running"),
            FakeTransport.row("windows-11", state: "suspended", bootMode: "windows"),
            FakeTransport.row("scratch", state: "stopped"),
        ])
        Snapshot.check("list-mixed-states", VMListView(model: model, open: { _ in }, settings: { _ in }, newVM: {}), width: 900, height: 560)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func emptyList() async {
        let model = await model([])
        Snapshot.check("list-empty", VMListView(model: model, open: { _ in }, settings: { _ in }, newVM: {}), width: 900, height: 560)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func actionError() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("scratch", state: "stopped")]
        let model = VMListModel(transport: host)
        await model.refresh()
        model.lastError = "scratch is busy: start"
        Snapshot.check("list-action-error", VMListView(model: model, open: { _ in }, settings: { _ in }, newVM: {}), width: 900, height: 560)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func popoverWithASettingsPanelOpen() async {
        let model = await model([
            FakeTransport.row("ubuntu-lab", state: "running", cpus: 4, memoryMB: 8192, timezone: "Europe/Berlin", clipboardSync: true, outbox: false),
            FakeTransport.row("scratch", state: "stopped"),
        ])
        let state = PopoverState()
        state.toggle("uuid-ubuntu-lab")
        Snapshot.check(
            "popover-settings-open", StatusPopoverView(model: model, state: state, act: { _, _ in }, showLibrary: {}, quit: {}),
            width: 340, height: 420)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func popoverWithMixedStates() async {
        let model = await model([
            FakeTransport.row("ubuntu-lab", state: "running"),
            FakeTransport.row("windows-11", state: "suspended", bootMode: "windows"),
            FakeTransport.row("scratch", state: "stopped"),
            FakeTransport.row("fresh", state: "stopped", activity: "start"),
        ])
        Snapshot.check(
            "popover-mixed-states", StatusPopoverView(model: model, act: { _, _ in }, showLibrary: {}, quit: {}),
            width: 340, height: 330)
    }
}

extension SnapshotTests {
    private func settingsModel(_ vm: VmSummary, shares: Bool = false) async -> VMSettingsModel {
        let host = FakeTransport()
        host.respond("host-info", with: FakeTransport.hostInfoFields)
        if shares {
            host.respond("share-list", with: [
                ("shares", .array([.map([("hostPath", .text("/Users/me/Projects")), ("guestPath", .text("/mnt/openvm/Projects"))])]))
            ])
        }
        let model = VMSettingsModel(vm: vm, transport: host)
        await model.load()
        return model
    }

    @Test(.enabled(if: Snapshot.enabled))
    func settingsOfAStoppedLinuxVm() async {
        let model = await settingsModel(FakeTransport.summary("lab", state: "stopped", timezone: "Europe/Berlin"), shares: true)
        Snapshot.check("settings-stopped-linux", VMSettingsView(model: model, close: {}), width: 520, height: 740)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func settingsOfARunningWindowsVm() async {
        let model = await settingsModel(FakeTransport.summary("win11", state: "running", bootMode: "windows", cpus: 4, memoryMB: 8192))
        Snapshot.check("settings-running-windows", VMSettingsView(model: model, close: {}), width: 520, height: 740)
    }
}

extension SnapshotTests {
    private func wizardModel(_ host: FakeTransport = FakeTransport(), linuxReady: Bool = true) async -> CreateWizardModel {
        host.respond("host-info", with: [
            ("maxCpus", .uint(8)), ("maxMemoryMB", .uint(16384)), ("freeDiskMB", .uint(500_000)),
            ("linuxReady", .bool(linuxReady)), ("hostWimlib", .bool(false)),
        ])
        let model = CreateWizardModel(transport: host, existingNames: ["lab"], pollInterval: .milliseconds(1))
        await model.load()
        return model
    }

    private func wizardView(_ model: CreateWizardModel) -> CreateWizardView { CreateWizardView(model: model, close: {}) }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardChoosesTheSystem() async {
        let model = await wizardModel()
        Snapshot.check("wizard-os", wizardView(model), width: 600, height: 540)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardRefusesAnX64Iso() async {
        let host = FakeTransport()
        host.respond("windows-iso-check", with: [
            ("usable", .bool(false)),
            ("problem", .text("This is not a Windows 11 ARM64 ISO. A Mac with Apple Silicon needs the ARM64 edition, not the x64 one.")),
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
        model.next()  // source (Linux files are ready)
        model.next()
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
        model.name = "demo"
        model.next(); model.next(); model.next()
        let run = Task { await model.create() }
        _ = await eventually { host.calls.contains("start") }
        Snapshot.check("wizard-working", wizardView(model), width: 600, height: 540)
        run.cancel()
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardAfterAFailedStart() async {
        let host = FakeTransport()
        host.respond("create", with: [])
        host.fail("start", with: HostError.remote("guest did not reach boot readiness with a responding openvm-tools agent; console tail:\nrandom: crng init done"))
        let model = await wizardModel(host)
        model.name = "demo"
        model.next(); model.next(); model.next()
        await model.create()
        Snapshot.check("wizard-failed", wizardView(model), width: 600, height: 540)
    }
}

extension SnapshotTests {
    @Test(.enabled(if: Snapshot.enabled))
    func librarySidebar() async {
        let model = await model([
            FakeTransport.row("ubuntu-lab", state: "running"),
            FakeTransport.row("windows-11", state: "suspended", bootMode: "windows"),
            FakeTransport.row("scratch", state: "stopped"),
        ])
        let nav = LibraryNav()
        nav.selection = .vm("uuid-ubuntu-lab")
        Snapshot.check("library-sidebar", LibrarySidebarView(model: model, nav: nav, newVM: {}), width: 260, height: 520)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func libraryPageOfOneVm() async {
        let model = await model([FakeTransport.row("windows-11", state: "suspended", bootMode: "windows", memoryMB: 8192)])
        let nav = LibraryNav()
        nav.selection = .vm("uuid-windows-11")
        Snapshot.check(
            "library-vm-page",
            LibraryDetailView(
                model: model, nav: nav, thumbnails: ThumbnailStore(directory: FileManager.default.temporaryDirectory),
                open: { _ in }, settings: { _ in }, newVM: {}),
            width: 700, height: 640)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func wizardSidebarOnTheResourcesStep() async {
        let wizard = CreateWizardModel(transport: FakeTransport(), existingNames: [], openWindow: { _ in })
        wizard.os = .linux
        wizard.next()
        wizard.next()
        Snapshot.check("wizard-sidebar", WizardSidebarView(model: wizard), width: 240, height: 360)
    }
}
