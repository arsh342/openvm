// The creation wizard against a real host: the cleanup promises, checked on disk.
//
// Opt-in (OPENVM_E2E=1): the test starts a real openvmd on a throwaway home and builds real media.
// It needs the Windows ISO at windowsImage/*.iso in the repository.
//   OPENVM_E2E=1 make test            cancelling a Windows media build (about 10 s)
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMApp

private nonisolated let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// A real openvmd on a throwaway home, stopped and removed when this goes away.
private nonisolated final class RealHost: @unchecked Sendable {
    let home: URL
    let client: DaemonClient
    private let process = Process()

    init() throws {
        home = URL(fileURLWithPath: "/tmp/ovm-e2e-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // The download cache is shared, so media is not downloaded again for every run.
        try? FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("cache"),
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openvm/cache"))
        let daemon = repo.appendingPathComponent(".build/debug/openvmd")
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force", "--sign", "-", "--entitlements", repo.appendingPathComponent("tools/build/vm.entitlements.xml").path,
            daemon.path,
        ]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        process.executableURL = daemon
        var env = ProcessInfo.processInfo.environment
        env["OPENVM_HOME"] = home.path
        env["OPENVM_PAYLOAD"] = repo.appendingPathComponent(".build/payload").path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        client = DaemonClient(socket: home.appendingPathComponent("openvmd.sock").path)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: home.appendingPathComponent("openvmd.sock").path) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw HostError.protocolFailure("the host did not start")
    }

    deinit {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: home)
    }

    var mediaFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("media").path)) ?? [])
    }

    var diskFolders: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("disks").path)) ?? [])
    }
}

/// Image files attached right now (a leftover mount keeps a multi-gigabyte file busy).
private func attachedImages() -> [String] {
    let info = Process()
    info.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    info.arguments = ["info"]
    let out = Pipe()
    info.standardOutput = out
    try? info.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    info.waitUntilExit()
    return text.split(separator: "\n").filter { $0.hasPrefix("image-path") }.map(String.init)
}

private func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(250))
    }
    return false
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENVM_E2E"] == "1"))
struct WizardEndToEndTests {
    private func summary(_ model: CreateWizardModel) {
        model.next(); model.next(); model.next()
    }

    @Test func cancellingAWindowsMediaBuildLeavesNothing() async throws {
        let iso = try FileManager.default.contentsOfDirectory(atPath: repo.appendingPathComponent("windowsImage").path)
            .first { $0.lowercased().hasSuffix(".iso") }
            .map { repo.appendingPathComponent("windowsImage/\($0)").path }
        guard let iso else {
            Issue.record("no ISO in windowsImage/")
            return
        }
        let before = attachedImages().count
        let host = try RealHost()
        let model = CreateWizardModel(transport: host.client, existingNames: [], pollInterval: .milliseconds(500)) { _ in }
        await model.load()
        model.os = .windows
        model.next()
        await model.chooseISO(iso)
        #expect(model.iso == .usable)
        model.name = "e2ewin"
        model.next()  // resources to account
        model.accountName = "e2e"
        model.accountPassword = "e2e-password"
        model.accountConfirm = "e2e-password"
        model.next()
        #expect(model.page == .summary)

        let run = Task { await model.create() }
        // The media is being written: the 22 GB image exists and the ISO and image are attached.
        let building = await waitUntil(60) {
            host.mediaFiles.contains("e2ewin.raw") && attachedImages().count >= before + 2
        }
        #expect(building, "the media build never got going")
        await model.cancel()
        await run.value

        #expect(model.page == .os)
        #expect(host.mediaFiles.isEmpty, "media left behind: \(host.mediaFiles)")
        #expect(attachedImages().count == before, "images left attached")
        #expect(((try? await host.client.listVMs()) ?? []).isEmpty)
        #expect(host.diskFolders.isEmpty)
    }
}
