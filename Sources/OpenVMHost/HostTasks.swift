// HostTasks — long jobs the host runs for a client: fetching the Linux guest files, and later
// building Windows media. A job is one of a fixed list (`plan(kind:)`), never a command a client
// names, so the socket cannot be used to run anything. Each runs as a child in its own process
// group, so cancelling stops it and everything it started (a fetch runs curl).
import Darwin
import Foundation
import OpenVMCore

/// A program to run: where it is, its arguments and what it adds to the environment.
nonisolated struct TaskPlan {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

nonisolated enum TaskError: Error, CustomStringConvertible {
    case unknownKind(String)
    case noPayload
    case missing(String)
    case cannotStart(String)

    var description: String {
        switch self {
        case .unknownKind(let kind): return "unknown task kind \(kind.debugDescription)"
        case .noPayload:
            return "this build has no guest payload to run it from (build the app with `make app`, or set OPENVM_PAYLOAD)"
        case .missing(let name): return "the guest payload has no \(name)"
        case .cannotStart(let why): return "could not start the task: \(why)"
        }
    }
}

nonisolated final class HostTasks: @unchecked Sendable {
    enum State: String, Sendable { case running, done, failed, cancelled }

    struct Snapshot: Equatable, Sendable {
        let state: State
        /// The last line the job wrote.
        let progress: String
        let error: String?
    }

    private final class Job {
        let pid: pid_t
        var state = State.running
        var progress = ""
        var tail: [String] = []
        var cancelRequested = false
        var error: String?
        let kind: String?
        init(pid: pid_t, kind: String?) {
            self.pid = pid
            self.kind = kind
        }
    }

    /// Finished jobs kept for a client to read; the oldest go first. Running ones always stay.
    private static let keepFinished = 20

    private let lock = NSLock()
    /// Held across a whole `start`, so "is one running?" and "start one" cannot interleave.
    private let startLock = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []

    var retainedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    // MARK: the fixed list

    /// The command for a kind of job, or why it cannot be run. The only inputs are the host's own:
    /// nothing a client sends becomes part of a command.
    static func plan(kind: String, payload: URL?, support: URL?) -> Result<TaskPlan, TaskError> {
        switch kind {
        case "fetch-linux":
            guard let payload else { return .failure(.noPayload) }
            let script = payload.appendingPathComponent("linux/fetch-linux.sh")
            guard FileManager.default.fileExists(atPath: script.path) else {
                return .failure(.missing("linux/fetch-linux.sh"))
            }
            var environment: [String: String] = [:]
            if let support { environment["OPENVM_SUPPORT"] = support.path }
            // A prebuilt unpacker, so a Mac without a C compiler can still fetch the guest.
            let zboot = payload.appendingPathComponent("linux/openvm-zboot")
            if FileManager.default.isExecutableFile(atPath: zboot.path) || FileManager.default.fileExists(atPath: zboot.path) {
                environment["OPENVM_ZBOOT"] = zboot.path
            }
            return .success(TaskPlan(executable: "/bin/sh", arguments: [script.path], environment: environment))
        default:
            return .failure(.unknownKind(kind))
        }
    }

    // MARK: running

    /// Starts a job. With a `kind`, a job of that kind that is already running is returned instead
    /// of a second one: two would write the same files and trip over each other.
    func start(_ plan: TaskPlan, kind: String? = nil) throws -> String {
        startLock.lock()
        defer { startLock.unlock() }
        if let kind {
            lock.lock()
            let running = order.first { jobs[$0]?.kind == kind && jobs[$0]?.state == .running }
            lock.unlock()
            if let running { return running }
        }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw TaskError.cannotStart(String(cString: strerror(errno))) }
        // Close-on-exec, so a child spawned for some other task (or anything else in this process)
        // never inherits these ends: the reader's end-of-file waits for every copy of the write end.
        fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        fcntl(fds[1], F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The child gets standard input from nowhere and both output streams into the pipe, and
        // nothing else: with CLOEXEC_DEFAULT every other descriptor is closed for it.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group, so one signal reaches the job and everything it started.
        // A clean signal state. Masks and ignored dispositions survive exec, and this process
        // ignores SIGPIPE (a client leaving mid-reply must not kill the host), which every job
        // would otherwise inherit.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in plan.environment { environment[key] = value }
        let arguments = ([plan.executable] + plan.arguments).map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            arguments.forEach { free($0) }
            variables.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, plan.executable, &actions, &attributes, arguments, variables)
        close(fds[1])
        guard result == 0 else {
            close(fds[0])
            throw TaskError.cannotStart("\(plan.executable): \(String(cString: strerror(result)))")
        }

        let id = UUID().uuidString.lowercased()
        let job = Job(pid: pid, kind: kind)
        lock.lock()
        jobs[id] = job
        order.append(id)
        lock.unlock()
        let reading = fds[0]
        Thread.detachNewThread { [self] in watch(job, id: id, output: reading) }
        return id
    }

    /// Reads the job's output until it ends, then records how it ended.
    private func watch(_ job: Job, id: String, output: Int32) {
        var line = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        func flush() {
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            line.removeAll()
            guard !text.isEmpty else { return }
            lock.lock()
            job.progress = String(text.prefix(200))
            job.tail.append(job.progress)
            if job.tail.count > 8 { job.tail.removeFirst() }
            lock.unlock()
        }
        while true {
            let n = read(output, &buffer, buffer.count)
            if n <= 0 { break }
            for byte in buffer.prefix(n) {
                // curl draws its progress bar with carriage returns, not newlines.
                if byte == 10 || byte == 13 { flush() } else { line.append(byte) }
            }
        }
        flush()
        close(output)
        var status: Int32 = 0
        waitpid(job.pid, &status, 0)

        lock.lock()
        if job.cancelRequested {
            job.state = .cancelled
        } else if status & 0x7f == 0 && (status >> 8) & 0xff == 0 {
            job.state = .done
        } else {
            job.state = .failed
            let why =
                status & 0x7f == 0 ? "exited with status \((status >> 8) & 0xff)" : "was stopped by signal \(status & 0x7f)"
            let context = job.tail.suffix(3).joined(separator: " | ")
            job.error = String("\(why)\(context.isEmpty ? "" : ": \(context)")".prefix(400))
        }
        prune()
        lock.unlock()
    }

    /// Drops the oldest finished jobs beyond what is kept. The caller holds the lock.
    private func prune() {
        let finished = order.filter { jobs[$0]?.state != .running }
        for id in finished.dropLast(Self.keepFinished) {
            jobs[id] = nil
            order.removeAll { $0 == id }
        }
    }

    func status(_ id: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = jobs[id] else { return nil }
        return Snapshot(state: job.state, progress: job.progress, error: job.error)
    }

    /// Stops a running job and everything it started. False when there was nothing to stop.
    func cancel(_ id: String) -> Bool {
        lock.lock()
        guard let job = jobs[id], job.state == .running else {
            lock.unlock()
            return false
        }
        job.cancelRequested = true
        let group = job.pid
        lock.unlock()
        kill(-group, SIGTERM)
        // A job that ignores SIGTERM is stopped for good after a few seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in
            lock.lock()
            let stillRunning = jobs[id]?.state == .running
            lock.unlock()
            if stillRunning { kill(-group, SIGKILL) }
        }
        return true
    }
}

nonisolated let tasks = HostTasks()

// MARK: the ops

nonisolated func taskStartOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let kind)? = r.arg("kind") else { return r.fail("task-start needs a kind") }
    switch HostTasks.plan(kind: kind, payload: GuestPayload.root, support: GuestBoot.supportBase()) {
    case .failure(let error): return r.fail(error.description)
    case .success(let plan):
        do {
            return r.ok([("taskId", .text(try tasks.start(plan, kind: kind)))])
        } catch {
            return r.fail("\(error)")
        }
    }
}

nonisolated func taskStatusOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("taskId"), let snapshot = tasks.status(id) else {
        return r.fail("no such task")
    }
    var fields: [(key: String, value: CBOR)] = [
        ("state", .text(snapshot.state.rawValue)), ("progress", .text(snapshot.progress)),
    ]
    if let error = snapshot.error { fields.append(("error", .text(error))) }
    return r.ok(fields)
}

nonisolated func taskCancelOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let id)? = r.arg("taskId") else { return r.fail("task-cancel needs a taskId") }
    guard tasks.status(id) != nil else { return r.fail("no such task") }
    return r.ok([("cancelled", .bool(tasks.cancel(id)))])
}
