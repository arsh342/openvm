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
    private func model(_ rows: [CBOR]) async -> VMListModel {
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
        Snapshot.check("list-mixed-states", VMListView(model: model, open: { _ in }), width: 820, height: 300)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func emptyList() async {
        let model = await model([])
        Snapshot.check("list-empty", VMListView(model: model, open: { _ in }), width: 820, height: 300)
    }

    @Test(.enabled(if: Snapshot.enabled))
    func actionError() async {
        let host = FakeTransport()
        host.rows = [FakeTransport.row("scratch", state: "stopped")]
        let model = VMListModel(transport: host)
        await model.refresh()
        model.lastError = "scratch is busy: start"
        Snapshot.check("list-action-error", VMListView(model: model, open: { _ in }), width: 820, height: 300)
    }
}
