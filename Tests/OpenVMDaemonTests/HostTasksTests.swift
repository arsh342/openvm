// Long jobs the host runs for a client (fetching the helper VM's files, building Windows media): a
// fixed list, never a command a client names, with progress and a way to stop them.
import Darwin
import Foundation
import Testing

@testable import OpenVMHost

nonisolated struct HostTasksTests {
    fileprivate func plan(_ script: String) -> TaskPlan {
        TaskPlan(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
    }

    /// Waits for a task to leave `running`, for up to `seconds`.
    fileprivate func finish(_ tasks: HostTasks, _ id: String, seconds: Double = 5) -> HostTasks.Snapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let snapshot = tasks.status(id), snapshot.state != .running { return snapshot }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return tasks.status(id)
    }

    @Test func taskReportsLastLineAndExit() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("echo one; echo two"))
        let done = finish(tasks, id)
        #expect(done?.state == .done)
        #expect(done?.progress == "two")
        #expect(done?.error == nil)
    }

    /// curl draws its progress bar with carriage returns, not newlines.
    @Test func carriageReturnsAlsoEndAProgressLine() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("printf 'a\\rb\\rc'"))
        #expect(finish(tasks, id)?.progress == "c")
    }

    @Test func failedTaskKeepsItsError() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("echo 'oops here' >&2; exit 3"))
        let done = finish(tasks, id)
        #expect(done?.state == .failed)
        #expect(done?.error?.contains("oops here") == true)
        #expect(done?.error?.contains("3") == true)
    }

    @Test func aVeryLongLineIsCutDown() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("head -c 5000 /dev/zero | tr '\\0' x; echo"))
        let done = finish(tasks, id)
        #expect((done?.progress.count ?? 0) <= 200)
    }

    /// The job's children must stop too: a fetch runs curl, and cancelling must not leave it downloading.
    @Test func cancelEndsTheProcessGroup() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("sleep 60 & echo $!; wait"))
        var child: pid_t = 0
        let started = Date()
        while child == 0, Date().timeIntervalSince(started) < 3 {
            child = pid_t(tasks.status(id)?.progress ?? "") ?? 0
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(child > 0)
        #expect(tasks.cancel(id))
        #expect(finish(tasks, id)?.state == .cancelled)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(kill(child, 0) == -1 && errno == ESRCH, "the child \(child) is still running")
    }

    @Test func cancellingAFinishedTaskDoesNothing() throws {
        let tasks = HostTasks()
        let id = try tasks.start(plan("true"))
        _ = finish(tasks, id)
        #expect(!tasks.cancel(id))
        #expect(tasks.status(id)?.state == .done)  // a late cancel does not rewrite what happened
    }

    @Test func unknownTaskIsAnError() {
        let tasks = HostTasks()
        #expect(tasks.status("nope") == nil)
        #expect(!tasks.cancel("nope"))
    }

    @Test func aTaskThatCannotStartSaysSo() {
        let tasks = HostTasks()
        #expect(throws: TaskError.self) {
            try tasks.start(TaskPlan(executable: "/no/such/program", arguments: [], environment: [:]))
        }
    }

    @Test func finishedTasksAreNotKeptForever() throws {
        let tasks = HostTasks()
        var ids: [String] = []
        for _ in 0..<30 {
            let id = try tasks.start(plan("true"))
            _ = finish(tasks, id)
            ids.append(id)
        }
        #expect(tasks.retainedCount <= 20)
        #expect(tasks.status(ids.last!) != nil)  // the newest is kept
        #expect(tasks.status(ids.first!) == nil)  // the oldest is not
    }

    // MARK: the fixed list of jobs

    private func payload(withFetchScript: Bool, zboot: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID().uuidString)")
        let linux = root.appendingPathComponent("linux")
        try FileManager.default.createDirectory(at: linux, withIntermediateDirectories: true)
        if withFetchScript { try Data("#!/bin/sh\n".utf8).write(to: linux.appendingPathComponent("fetch-linux.sh")) }
        if zboot { try Data().write(to: linux.appendingPathComponent("openvm-zboot")) }
        return root
    }

    @Test func fetchLinuxIsAFixedCommand() throws {
        let root = try payload(withFetchScript: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = URL(fileURLWithPath: "/tmp/support-test")
        guard case .success(let plan) = HostTasks.plan(kind: "fetch-linux", payload: root, support: support) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.executable == "/bin/sh")
        #expect(plan.arguments == [root.appendingPathComponent("linux/fetch-linux.sh").path])
        #expect(plan.environment["OPENVM_SUPPORT"] == "/tmp/support-test")
        #expect(plan.environment["OPENVM_ZBOOT"] == root.appendingPathComponent("linux/openvm-zboot").path)
    }

    @Test func aKindOutsideTheListIsRefused() {
        for kind in ["rm -rf /", "fetch-linux; id", "", "FETCH-LINUX", "../fetch-linux", "windows-shell"] {
            guard case .failure(let error) = HostTasks.plan(kind: kind, payload: nil, support: nil) else {
                Issue.record("\(kind) was accepted")
                continue
            }
            #expect(error.description.contains("unknown task"), "\(kind)")
        }
    }

    @Test func aBuildWithoutAPayloadSaysSo() throws {
        guard case .failure(let none) = HostTasks.plan(kind: "fetch-linux", payload: nil, support: nil) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(none.description.contains("payload"))
        let empty = try payload(withFetchScript: false)
        defer { try? FileManager.default.removeItem(at: empty) }
        guard case .failure(let missing) = HostTasks.plan(kind: "fetch-linux", payload: empty, support: nil) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(missing.description.contains("fetch-linux.sh"))
    }
}

extension HostTasksTests {
    /// A child must not inherit another task's output pipe: its end-of-file would then wait for
    /// that child to exit, so a quick task could look "running" for as long as a slow one lives.
    @Test func aSlowTaskDoesNotHoldAQuickOnesOutputOpen() throws {
        let tasks = HostTasks()
        let slow = try tasks.start(plan("sleep 8"))
        defer { _ = tasks.cancel(slow) }
        let quick = try tasks.start(plan("echo hi"))
        let done = finish(tasks, quick, seconds: 2)  // far less than the slow task's 8 seconds
        #expect(done?.state == .done)
        #expect(done?.progress == "hi")
        #expect(tasks.status(slow)?.state == .running)
    }
}

extension HostTasksTests {
    /// The host ignores SIGPIPE (a client leaving mid-reply must not kill it). An ignored signal
    /// stays ignored across exec, so without a reset every job would inherit that: `curl | head`
    /// would no longer be stopped by SIGPIPE, and a job could ignore SIGTERM and not be cancelled.
    @Test func aJobGetsDefaultSignalsEvenWhenTheHostIgnoresSigpipe() throws {
        signal(SIGPIPE, SIG_IGN)  // as the host does while serving
        let tasks = HostTasks()
        let id = try tasks.start(plan("kill -PIPE $$; echo survived"))
        let done = finish(tasks, id)
        #expect(done?.state == .failed)
        #expect(done?.error?.contains("signal 13") == true)  // it died of SIGPIPE, as a default process does
        #expect(done?.progress != "survived")
    }
}

extension HostTasksTests {
    /// Two fetches write the same temporary files and trip over each other (measured: the second
    /// failed with a missing file while the first was still downloading). So a kind that is
    /// already running is not started twice; the caller is handed the running task.
    @Test func startingARunningKindAgainReturnsTheRunningTask() throws {
        let tasks = HostTasks()
        let first = try tasks.start(plan("sleep 5"), kind: "fetch")
        defer { _ = tasks.cancel(first) }
        let second = try tasks.start(plan("sleep 5"), kind: "fetch")
        #expect(second == first)
        #expect(tasks.retainedCount == 1)  // no second process was started
    }

    @Test func aFinishedKindCanBeStartedAgain() throws {
        let tasks = HostTasks()
        let first = try tasks.start(plan("true"), kind: "fetch")
        _ = finish(tasks, first)
        let second = try tasks.start(plan("true"), kind: "fetch")
        #expect(second != first)
    }

    @Test func differentKindsRunSideBySide() throws {
        let tasks = HostTasks()
        let one = try tasks.start(plan("sleep 5"), kind: "fetch")
        defer { _ = tasks.cancel(one) }
        let two = try tasks.start(plan("sleep 5"), kind: "media")
        defer { _ = tasks.cancel(two) }
        #expect(one != two)
    }
}

extension HostTasksTests {
    /// Two clients asking at the same instant must still get one task, not two.
    @Test func simultaneousStartsOfOneKindMakeOneTask() throws {
        let tasks = HostTasks()
        let ids = IDCollector()
        let group = DispatchGroup()
        for _ in 0..<12 {
            DispatchQueue.global().async(group: group) {
                if let id = try? tasks.start(plan("sleep 5"), kind: "fetch") { ids.add(id) }
            }
        }
        group.wait()
        defer { for id in ids.all { _ = tasks.cancel(id) } }
        #expect(Set(ids.all).count == 1)
        #expect(tasks.retainedCount == 1)
    }

}

nonisolated final class IDCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.append(id)
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

// MARK: Windows media

extension HostTasksTests {
    private struct Fixture {
        let payload: URL, iso: URL, home: URL
        func cleanup() {
            for url in [payload, iso.deletingLastPathComponent(), home] { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func fixture(withWindows: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        let payload = base.appendingPathComponent("wp-\(UUID().uuidString)")
        try fm.createDirectory(at: payload.appendingPathComponent("linux"), withIntermediateDirectories: true)
        if withWindows {
            try fm.createDirectory(at: payload.appendingPathComponent("windows/prebuilt"), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: payload.appendingPathComponent("windows/mk-windows-media.sh"))
        }
        let isoDir = base.appendingPathComponent("isos-\(UUID().uuidString)")
        try fm.createDirectory(at: isoDir, withIntermediateDirectories: true)
        let iso = isoDir.appendingPathComponent("Win11.iso")
        try Data("iso".utf8).write(to: iso)
        let home = base.appendingPathComponent("home-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return Fixture(payload: payload, iso: iso, home: home)
    }

    private func mediaPlan(
        _ f: Fixture, name: String = "win", iso: String? = nil, wimlib: String? = "/opt/homebrew/bin/wimlib-imagex",
        helper: String? = nil, helperReady: Bool = false
    ) -> Result<TaskPlan, TaskError> {
        HostTasks.plan(
            kind: "windows-media", payload: f.payload, support: nil,
            inputs: TaskInputs(
                arguments: ["iso": iso ?? f.iso.path, "name": name], home: f.home, wimlib: wimlib, helper: helper,
                helperReady: helperReady))
    }

    @Test func windowsMediaIsAFixedCommand() throws {
        let f = try fixture()
        defer { f.cleanup() }
        guard case .success(let plan) = mediaPlan(f) else {
            Issue.record("expected a plan")
            return
        }
        let output = f.home.appendingPathComponent("media/win.raw").path
        #expect(plan.executable == "/bin/sh")
        #expect(plan.arguments == [f.payload.appendingPathComponent("windows/mk-windows-media.sh").path, f.iso.path, output])
        #expect(plan.output == output)
        #expect(plan.environment["OPENVM_WIMLIB"] == "/opt/homebrew/bin/wimlib-imagex")
        #expect(plan.environment["OPENVM_WIM_EXEC"] == nil)  // the Mac's own wimlib is faster, so no helper
        #expect(plan.environment["OPENVM_PREBUILT"] == f.payload.appendingPathComponent("windows/prebuilt").path)
        #expect(plan.environment["OPENVM_WINDOWS_FILES"] == f.payload.appendingPathComponent("windows/scripts").path)
        #expect(plan.environment["OPENVM_CACHE"] == f.home.appendingPathComponent("cache").path)
    }

    @Test func withoutWimlibTheHelperIsUsed() throws {
        let f = try fixture()
        defer { f.cleanup() }
        guard case .success(let plan) = mediaPlan(f, wimlib: nil, helper: "/Applications/openvm.app/Contents/MacOS/openvm", helperReady: true) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.environment["OPENVM_WIM_EXEC"] == "/Applications/openvm.app/Contents/MacOS/openvm")
        #expect(plan.environment["OPENVM_WIMLIB"] == nil)
    }

    @Test func withoutWimlibOrAHelperItSaysWhat() throws {
        let f = try fixture()
        defer { f.cleanup() }
        guard case .failure(let none) = mediaPlan(f, wimlib: nil, helper: nil) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(none.description.contains("wimlib"))
    }

    /// The helper VM boots from its fetched files and the overlay, so it needs both.
    @Test func theHelperNeedsItsFiles() throws {
        let f = try fixture()
        defer { f.cleanup() }
        guard case .failure(let error) = mediaPlan(f, wimlib: nil, helper: "/x/openvm", helperReady: false) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.description.contains("fetch-linux"))
    }

    @Test func aBadIsoIsRefused() throws {
        let f = try fixture()
        defer { f.cleanup() }
        for iso in ["/etc/passwd", "relative.iso", "/no/such.iso", "/tmp", "", "x.iso; rm -rf /", f.payload.path] {
            guard case .failure = mediaPlan(f, iso: iso) else {
                Issue.record("\(iso.debugDescription) was accepted")
                continue
            }
        }
    }

    /// The media script deletes its output path first, so the client must never choose it.
    @Test func theOutputIsAlwaysUnderTheMediaFolder() throws {
        let f = try fixture()
        defer { f.cleanup() }
        for name in ["win", "a_b-1", "Windows11"] {
            guard case .success(let plan) = mediaPlan(f, name: name) else {
                Issue.record("\(name) was refused")
                continue
            }
            #expect(plan.output?.hasPrefix(f.home.appendingPathComponent("media/").path) == true)
            #expect(plan.output?.hasSuffix("/\(name).raw") == true)
        }
        for name in ["../evil", "a b", "", "x/y", "/etc/passwd", "-rf", "a;b", String(repeating: "a", count: 65), ".."] {
            guard case .failure = mediaPlan(f, name: name) else {
                Issue.record("\(name.debugDescription) was accepted as a name")
                continue
            }
        }
    }

    @Test func aPayloadWithoutWindowsSupportSaysSo() throws {
        let f = try fixture(withWindows: false)
        defer { f.cleanup() }
        guard case .failure(let error) = mediaPlan(f) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.description.contains("Windows"))
    }
}

extension HostTasksTests {
    /// The downloads (virtio-win, WinFsp, the sound driver) are about 900 MB, so the cache is named
    /// explicitly and lives under the host's home; a script run without it keeps using
    /// ~/.openvm/cache, whatever throwaway home it runs in (checked in the script below).
    @Test func theMediaTaskNamesItsDownloadCache() throws {
        let f = try fixtureForCache()
        defer { f.cleanup() }
        guard case .success(let plan) = HostTasks.plan(
            kind: "windows-media", payload: f.payload, support: nil,
            inputs: TaskInputs(arguments: ["iso": f.iso.path, "name": "w"], home: f.home, wimlib: "/x/wimlib-imagex"))
        else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.environment["OPENVM_CACHE"] == f.home.appendingPathComponent("cache").path)
    }

    private func fixtureForCache() throws -> (payload: URL, iso: URL, home: URL, cleanup: () -> Void) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
        let payload = base.appendingPathComponent("wc-\(UUID().uuidString)")
        try fm.createDirectory(at: payload.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data().write(to: payload.appendingPathComponent("windows/mk-windows-media.sh"))
        let dir = base.appendingPathComponent("wci-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = dir.appendingPathComponent("a.iso")
        try Data("x".utf8).write(to: iso)
        let home = base.appendingPathComponent("wch-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return (payload, iso, home, { for u in [payload, dir, home] { try? fm.removeItem(at: u) } })
    }

    /// A smoke runs in a throwaway home. If the script's cache followed OPENVM_HOME, each smoke
    /// would download 900 MB again (measured: it did, after the cache moved under the home).
    @Test func theScriptsCacheDoesNotFollowAThrowawayHome() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("tools/build/mk-windows-media.sh"), encoding: .utf8)
        let line = script.split(separator: "\n").first { $0.hasPrefix("CACHE=") }.map(String.init) ?? ""
        #expect(line.contains("OPENVM_CACHE"))
        #expect(line.contains("$HOME/.openvm/cache"))
        #expect(!line.contains("OPENVM_HOME"))
    }
}

// MARK: a job that makes a file removes it if it did not finish

extension HostTasksTests {
    private func output() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("taskout-\(UUID().uuidString).raw").path
    }

    private func writing(_ path: String, then script: String) -> TaskPlan {
        TaskPlan(
            executable: "/bin/sh", arguments: ["-c", "echo partial > \"$0\"; \(script)", path], environment: [:],
            output: path)
    }

    /// Media is 22 GB: a build that was cancelled or failed must not leave its half-written image.
    @Test func aCancelledTaskRemovesItsOutput() throws {
        let tasks = HostTasks()
        let path = output()
        let id = try tasks.start(writing(path, then: "sleep 30"))
        let started = Date()
        while !FileManager.default.fileExists(atPath: path), Date().timeIntervalSince(started) < 3 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(tasks.cancel(id))
        #expect(finish(tasks, id)?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aFailedTaskRemovesItsOutput() throws {
        let tasks = HostTasks()
        let path = output()
        let id = try tasks.start(writing(path, then: "exit 3"))
        #expect(finish(tasks, id)?.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aFinishedTaskKeepsItsOutput() throws {
        let tasks = HostTasks()
        let path = output()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id = try tasks.start(writing(path, then: "true"))
        #expect(finish(tasks, id)?.state == .done)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

/// The account reaches the media script in its environment, escaped, and never on its command line.
@Suite struct WindowsMediaAccountTests {
    private func plan(_ extra: [String: String]) throws -> Result<TaskPlan, TaskError> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acct-\(UUID().uuidString)")
        let payload = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("windows"), withIntermediateDirectories: true)
        try Data().write(to: payload.appendingPathComponent("windows/mk-windows-media.sh"))
        let iso = root.appendingPathComponent("Win.iso")
        try Data().write(to: iso)
        var arguments = ["iso": iso.path, "name": "win"]
        arguments.merge(extra) { $1 }
        return HostTasks.plan(
            kind: "windows-media", payload: payload, support: nil,
            inputs: TaskInputs(arguments: arguments, home: root, wimlib: "/opt/homebrew/bin/wimlib-imagex"))
    }

    @Test func theAccountGoesInTheEnvironmentNotTheArguments() throws {
        guard case .success(let plan) = try plan(["user": "arsh", "password": "a&b", "autologon": "no"]) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.environment["OPENVM_WIN_USER"] == "arsh")
        #expect(plan.environment["OPENVM_WIN_PASSWORD"] == "a\\&amp;b")
        #expect(plan.environment["OPENVM_WIN_AUTOLOGON"] == "0")
        #expect(!plan.arguments.joined().contains("a&b"))
    }

    @Test func withoutAnAccountTheScriptsDefaultsStand() throws {
        guard case .success(let plan) = try plan([:]) else {
            Issue.record("expected a plan")
            return
        }
        #expect(plan.environment["OPENVM_WIN_USER"] == nil)
        #expect(plan.environment["OPENVM_WIN_PASSWORD"] == nil)
    }

    @Test func aBadAccountIsRefusedWithoutEchoingThePassword() throws {
        guard case .failure(let error) = try plan(["user": "arsh", "password": "bad\npassword"]) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(!error.description.contains("password\n"))
        #expect(!error.description.contains("bad"))
        guard case .failure = try plan(["user": "a/b", "password": "fine"]) else {
            Issue.record("expected a refusal")
            return
        }
    }
}
