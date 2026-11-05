// Tests for the generated Linux installer and services.
import Foundation
import Testing

/// The generated first-boot installer and OpenRC services, read from a real overlay.
private final class Overlay: Sendable {
    static let shared = Overlay()
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    let installer, backend, session, desktop: String

    private init() {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("openvm-overlay-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        let script = Overlay.root.appendingPathComponent("tools/build/mk-guest-overlay.sh").path
        guard run(script, [output.path], directory: Overlay.root).status == 0 else {
            fatalError("mk-guest-overlay.sh failed")
        }
        func read(_ path: String) -> String {
            (try? String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)) ?? ""
        }
        installer = read("stage/etc/local.d/openvm-tools.start")
        backend = read("stage/opt/openvm/openvm-clipboard-backend.sh")
        session = read("stage/usr/local/bin/openvm-clipboard-session")
        desktop = read("stage/etc/xdg/autostart/openvm-clipboard.desktop")
    }

    /// The body of a `<<'NAME'` heredoc in the installer.
    func heredoc(_ name: String) -> String { body(of: name) }

    private func body(of name: String) -> String {
        let start = installer.components(separatedBy: "<<'\(name)'\n")
        guard start.count > 1 else { return "" }
        return start[1].components(separatedBy: "\n\(name)")[0]
    }

    var service: String { heredoc("SERVICE") }
    var clipdesk: String { heredoc("CLIPDESK") }
    var netstart: String { heredoc("NETSTART") }
}

@discardableResult
private func run(
    _ tool: String, _ arguments: [String], input: String? = nil,
    environment: [String: String]? = nil, directory: URL? = nil
) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (-1, "") }
    if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
    try? stdin.fileHandleForWriting.close()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func temporaryDirectory(_ prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func order(_ text: String, _ needle: String, before end: String.Index) -> String.Index? {
    text.range(of: needle, options: .backwards, range: text.startIndex..<end)?.lowerBound
}

@Suite(.serialized) struct GuestOverlayTests {
    fileprivate let overlay = Overlay.shared

    @Test func generatedScriptsHaveValidShellSyntax() {
        for script in [
            overlay.installer, overlay.service, overlay.clipdesk, overlay.backend,
            overlay.session, overlay.netstart,
        ] {
            #expect(!script.isEmpty)
            #expect(run("/bin/sh", ["-n"], input: script).status == 0)
        }
    }

    @Test func installationAbortsOnFailedTargetWrites() {
        #expect(overlay.installer.components(separatedBy: "\n")[1] == "set -eu")
    }

    @Test func onlyTheOpenRCServiceStartsThePersistentAgent() {
        #expect(!overlay.installer.contains("<<'AGENT'"))
        #expect(overlay.installer.contains("rm -f /mnt/etc/local.d/openvm-tools.start"))
        #expect(overlay.installer.contains("/mnt/etc/runlevels/default/openvm-tools"))
        #expect(overlay.service.contains("output_log=\"/dev/console\""))
        #expect(overlay.service.contains("error_log=\"/dev/console\""))
    }

    @Test func installedFilesystemsAreUnmountedBeforeReady() throws {
        let text = overlay.installer
        let ready = try #require(text.range(of: "echo \"OPENVM_DISK_READY=")).lowerBound
        let copies = try #require(order(text, "cp ./openvm-tools", before: ready))
        let sync = try #require(order(text, "\n            sync\n", before: ready))
        let boot = try #require(order(text, "umount /mnt/boot", before: ready))
        let root = try #require(order(text, "umount /mnt\n", before: ready))
        #expect(copies < sync)
        #expect(sync < boot)
        #expect(boot < root)
    }

    @Test func clipboardSessionBridgeIsInstalledForDesktopLogins() {
        #expect(overlay.installer.contains("openvm-clipboard-backend.sh"))
        #expect(overlay.desktop.contains("openvm-clipboard-session"))
        #expect(overlay.session.contains("\"$XDG_RUNTIME_DIR/openvm-clipboard.env\""))
    }

    @Test func clipboardDesktopDependenciesReachTheInstalledRoot() {
        #expect(overlay.installer.contains("apk --root /mnt add xvfb xorg-server"))
        #expect(overlay.installer.contains("xfce4-session"))
        #expect(!overlay.installer.contains("xfce4-power-manager"))
    }

    @Test func clipboardDesktopServicePublishesAnX11Session() {
        #expect(overlay.installer.contains("<<'CLIPDESK'"))
        #expect(overlay.clipdesk.contains("command=\"/opt/openvm/openvm-desktop-server\""))
        let session = overlay.heredoc("SESSION")
        #expect(session.contains("command=\"/opt/openvm/openvm-desktop-session\""))
        #expect(session.contains("command_background=\"yes\""))
        #expect(session.contains("need openvm-clipdesk"))
        #expect(overlay.installer.contains("/mnt/etc/runlevels/default/openvm-session"))
        #expect(overlay.installer.contains("/mnt/etc/runlevels/default/openvm-clipdesk"))
        #expect(overlay.installer.contains("/mnt/etc/asound.conf"))
    }

    /// The netboot image configures eth0 from its initramfs, so a persistent install
    /// comes up with no network unless it does this itself.
    @Test func installedRootBringsUpEth0ForTheHostGateway() {
        #expect(overlay.installer.contains("<<'NETSTART'"))
        #expect(overlay.installer.contains("/mnt/etc/local.d/net.start"))
        for needle in ["udhcpc", "eth0", "\"$ip/$mask\"", "$router", "-s \"$0\"", "openvm: eth0"] {
            #expect(overlay.netstart.contains(needle))
        }
        // busybox's udhcpc exports $ip/$mask; a script using the ISC names does nothing.
        #expect(!overlay.netstart.contains("$ipaddr"))
        #expect(!overlay.netstart.contains("$subnetmask"))
    }

    @Test func installerUsesNoPython() {
        #expect(!overlay.installer.contains("python"))
        #expect(overlay.installer.contains("openvm-zboot"))
    }

    @Test func rootBackendDoesNotExecuteSessionEnvironmentAsShell() {
        #expect(!overlay.backend.contains(". \"$session_file\""))
        #expect(!overlay.backend.contains("eval"))
        for key in ["WAYLAND_DISPLAY", "DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY"] {
            #expect(overlay.backend.contains("\(key)=*"))
        }
    }

    @Test func clipboardBackendReadsAndWritesThePublishedUserSession() throws {
        let root = temporaryDirectory("openvm-clipboard-test")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        let runtime = root.appendingPathComponent("run/user/1000")
        let bin = root.appendingPathComponent("bin")
        try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let clipboard = root.appendingPathComponent("clipboard")
        let executed = root.appendingPathComponent("executed")
        let published = runtime.appendingPathComponent("openvm-clipboard.env")
        try """
        WAYLAND_DISPLAY=wayland-0
        DISPLAY=
        XDG_RUNTIME_DIR=\(runtime.path)
        XAUTHORITY=
        EVIL=$(touch \(executed.path))

        """.write(to: published, atomically: true, encoding: .utf8)
        for (name, body) in [
            ("wl-copy", "cat > \"$CLIPBOARD_FIXTURE\""), ("wl-paste", "cat \"$CLIPBOARD_FIXTURE\""),
        ] {
            let tool = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: tool, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        }
        let backend = root.appendingPathComponent("backend.sh")
        try overlay.backend.replacingOccurrences(of: "/run/user/*/openvm-clipboard.env", with: published.path)
            .write(to: backend, atomically: true, encoding: .utf8)
        let environment = ["PATH": "\(bin.path):/usr/bin:/bin", "CLIPBOARD_FIXTURE": clipboard.path]
        let payload = "guest clipboard 🌱"
        #expect(
            run("/bin/sh", [backend.path, "write"], input: payload, environment: environment).status == 0)
        let result = run("/bin/sh", [backend.path, "read"], environment: environment)
        #expect(result.status == 0)
        #expect(result.output == payload)
        #expect(!manager.fileExists(atPath: executed.path))
    }

    @Test func sessionHookWritesPrivateRuntimeEnvironment() throws {
        let runtime = temporaryDirectory("openvm-session-test")
        defer { try? FileManager.default.removeItem(at: runtime) }
        let script = Overlay.root.appendingPathComponent("tools/guest/openvm-clipboard-session.sh").path
        let environment = [
            "XDG_RUNTIME_DIR": runtime.path, "WAYLAND_DISPLAY": "wayland-3", "DISPLAY": "", "XAUTHORITY": "",
        ]
        #expect(run("/bin/sh", [script], environment: environment).status == 0)
        let published = runtime.appendingPathComponent("openvm-clipboard.env")
        let mode = try FileManager.default.attributesOfItem(atPath: published.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try String(contentsOf: published, encoding: .utf8).contains("WAYLAND_DISPLAY=wayland-3"))
    }
}
