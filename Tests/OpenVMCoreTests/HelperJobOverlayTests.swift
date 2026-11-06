// The helper-VM boot script in the install overlay: a boot with `openvm.job=wim` runs one job
// from a shared folder and powers off; any other boot is left alone. Run here against fake
// `mount`, `apk` and `poweroff`, so every branch, including the failures, needs no VM.
import Foundation
import Testing

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// A scratch directory with fake commands that record what they were called with.
private final class Sandbox: @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("job-sandbox-\(UUID().uuidString)")
    var bin: URL { dir.appendingPathComponent("bin") }
    var mount: URL { dir.appendingPathComponent("mnt") }
    var calls: URL { dir.appendingPathComponent("calls.log") }
    var status: URL { mount.appendingPathComponent("job/status") }

    init(jobScript: String, failing: Set<String> = []) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: mount.appendingPathComponent("job"), withIntermediateDirectories: true)
        try jobScript.write(to: mount.appendingPathComponent("job/job.sh"), atomically: true, encoding: .utf8)
        try "3.22.2\n".write(to: dir.appendingPathComponent("alpine-release"), atomically: true, encoding: .utf8)
        for name in ["mount", "apk", "modprobe", "poweroff", "sync"] {
            let exit = failing.contains(name) ? 1 : 0
            let script = "#!/bin/sh\necho \"\(name) $*\" >> '\(calls.path)'\nexit \(exit)\n"
            let file = bin.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        FileManager.default.createFile(atPath: calls.path, contents: nil)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func cmdline(_ text: String) throws -> String {
        let file = dir.appendingPathComponent("cmdline")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    /// Runs a generated overlay script in the foreground, with the fakes first on PATH.
    func run(_ script: String, cmdline: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "OPENVM_CMDLINE": cmdline, "OPENVM_JOB_MOUNT": mount.path,
            "OPENVM_JOB_LOG": dir.appendingPathComponent("log").path,
            "OPENVM_ALPINE_RELEASE": dir.appendingPathComponent("alpine-release").path,
            "OPENVM_JOB_FOREGROUND": "1",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    var recorded: [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var statusText: String? { try? String(contentsOf: status, encoding: .utf8) }
}

/// The overlay as the host builds it.
private let overlay: (job: String, agent: String) = {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("job-overlay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: out) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [root.appendingPathComponent("tools/build/mk-guest-overlay.sh").path, out.path]
    process.currentDirectoryURL = root
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    func read(_ path: String) -> String {
        (try? String(contentsOf: out.appendingPathComponent("stage/etc/local.d/\(path)"), encoding: .utf8)) ?? ""
    }
    return (read("openvm-job.start"), read("openvm-tools.start"))
}()

/// Written to disk once, so each test runs the script from a file.
private func scriptFile(_ text: String, in sandbox: Sandbox, named name: String) throws -> String {
    let file = sandbox.dir.appendingPathComponent(name)
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file.path
}

@Suite(.serialized) struct HelperJobOverlayTests {
    @Test func theOverlayHasAJobScript() {
        #expect(!overlay.job.isEmpty)
        #expect(overlay.job.hasPrefix("#!/bin/sh"))
    }

    @Test func anOrdinaryBootDoesNothing() throws {
        let sandbox = try Sandbox(jobScript: "touch ran\n")
        let script = try scriptFile(overlay.job, in: sandbox, named: "job.start")
        let result = try sandbox.run(script, cmdline: sandbox.cmdline("console=hvc0 ip=dhcp openvm.install=1"))
        #expect(result.status == 0)
        #expect(sandbox.recorded.isEmpty)  // no mount, no apk, no poweroff
        #expect(sandbox.statusText == nil)
    }

    @Test func aJobBootMountsInstallsRunsAndPowersOff() throws {
        let sandbox = try Sandbox(jobScript: "echo \"args: $1 $2\" > \"$2/saw\"\n")
        let script = try scriptFile(overlay.job, in: sandbox, named: "job.start")
        let result = try sandbox.run(script, cmdline: sandbox.cmdline("console=hvc0 openvm.job=wim"))
        #expect(result.status == 0, "\(result.output)")
        let calls = sandbox.recorded
        #expect(calls.contains { $0.hasPrefix("mount -t virtiofs job ") })
        let install = calls.first { $0.hasPrefix("apk add") } ?? ""
        #expect(install.contains("wimlib"))
        // wimlib is in Alpine's community repository, not main (checked against the package index)
        #expect(install.contains("/alpine/v3.22/community"))
        #expect(install.contains("/alpine/v3.22/main"))
        #expect(calls.last?.hasPrefix("poweroff") == true)
        #expect(sandbox.statusText == "ok\n")
        // the job was given the ISO folder and the job folder, in that order
        let saw = try String(contentsOf: sandbox.mount.appendingPathComponent("job/saw"), encoding: .utf8)
        #expect(saw.contains("\(sandbox.mount.path)/iso"))
        #expect(saw.contains("\(sandbox.mount.path)/job"))
    }

    @Test func aFailedJobIsReportedAndStillPowersOff() throws {
        let sandbox = try Sandbox(jobScript: "echo broken >&2; exit 4\n")
        let script = try scriptFile(overlay.job, in: sandbox, named: "job.start")
        let result = try sandbox.run(script, cmdline: sandbox.cmdline("openvm.job=wim"))
        #expect(result.status != 0)
        #expect(sandbox.statusText?.hasPrefix("error:") == true)
        #expect(sandbox.statusText?.contains("job failed") == true)
        #expect(sandbox.recorded.contains { $0.hasPrefix("poweroff") })  // never left running
    }

    @Test func noNetworkIsReportedAsSuch() throws {
        let sandbox = try Sandbox(jobScript: "touch ran\n", failing: ["apk"])
        let script = try scriptFile(overlay.job, in: sandbox, named: "job.start")
        _ = try sandbox.run(script, cmdline: sandbox.cmdline("openvm.job=wim"))
        #expect(sandbox.statusText?.contains("online") == true)
        #expect(!FileManager.default.fileExists(atPath: sandbox.mount.appendingPathComponent("job/ran").path))
        #expect(sandbox.recorded.contains { $0.hasPrefix("poweroff") })
    }

    @Test func aFolderThatCannotBeMountedPowersOffWithoutReporting() throws {
        let sandbox = try Sandbox(jobScript: "touch ran\n", failing: ["mount"])
        let script = try scriptFile(overlay.job, in: sandbox, named: "job.start")
        _ = try sandbox.run(script, cmdline: sandbox.cmdline("openvm.job=wim"))
        #expect(!sandbox.recorded.contains { $0.hasPrefix("apk") })  // nothing runs without its folder
        #expect(sandbox.recorded.contains { $0.hasPrefix("poweroff") })
    }

    @Test func theAgentScriptStandsDownForAJob() throws {
        #expect(!overlay.agent.isEmpty)
        let sandbox = try Sandbox(jobScript: "touch ran\n")
        let script = try scriptFile(overlay.agent, in: sandbox, named: "tools.start")
        let result = try sandbox.run(script, cmdline: sandbox.cmdline("openvm.job=wim"))
        #expect(result.status == 0)
        #expect(!result.output.contains("preparing virtio-vsock"))  // it did not start its own boot work
    }
}
