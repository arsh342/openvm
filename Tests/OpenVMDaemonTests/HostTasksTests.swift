// Long jobs the host runs for a client (fetching the Linux files, building Windows media): a
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
    private func finish(_ tasks: HostTasks, _ id: String, seconds: Double = 5) -> HostTasks.Snapshot? {
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
