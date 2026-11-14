// InstallerDownloads — the host downloads a Linux installer for a catalog entry, so the download lives
// as long as the host, not as long as a window.
//
// A client names a catalog entry and nothing else: never an address, a path or a file name. The host
// reads the vendor's own index over HTTPS to find the file and its SHA-256 (InstallerSources), writes
// the download to `<entry>-<file>.part`, and only after the size and the hash match, and the existing
// ISO check passes, renames it into place. A file that fails is removed and never used.
//
// A download that stops (cancelled, the network went, openVM quit) keeps its `.part`, and the next
// start for the same entry asks the server for the rest (an HTTP Range request). The whole file is
// hashed once at the end, so a part that no longer matches is caught there.
import CryptoKit
import Foundation
import OpenVMCore
import os

nonisolated final class InstallerDownloads: @unchecked Sendable {
    enum State: String, Sendable { case running, done, failed, cancelled }

    struct Snapshot: Equatable, Sendable {
        let entry: String
        let state: State
        let bytesDone: UInt64
        /// Nil until the server has said.
        let bytesTotal: UInt64?
        let bytesPerSecond: Double
        /// The verified file, once done.
        let path: String?
        let error: String?
        /// Names the failure for the app (FailureMessage): download-failed, download-damaged, no-space,
        /// installer-not-found.
        let code: String?
    }

    /// A file in the installer cache.
    struct Cached: Equatable, Sendable {
        let entry: String
        let file: String
        let path: String
        let bytes: UInt64
        /// False for a `.part`: a download that has not finished.
        let complete: Bool
    }

    /// What a download depends on, so tests can point it at a local server and a small disk.
    struct Environment: Sendable {
        var directory: URL
        var entries: [InstallerCatalog.Entry] = InstallerCatalog.entries
        var indexURL: @Sendable (InstallerCatalog.Entry) -> URL? = {
            InstallerSources.indexURL(for: $0.source)
        }
        /// The hosts an entry's index may be served from, besides the one its address names.
        var indexHosts: @Sendable (InstallerCatalog.Entry) -> [String] = {
            InstallerSources.indexHosts(for: $0.source)
        }
        /// Off only in tests, which serve from this Mac over plain HTTP.
        var requireHTTPS = true
        var freeBytes: @Sendable () -> UInt64
        /// The existing installer check: why the file cannot start here, or nil.
        var check: @Sendable (URL) -> String?
    }

    private enum Failure: Error {
        case notFound(String)
        case noSpace(String)
        case damaged(String)
        case failed(String)
        case cancelled

        var code: String? {
            switch self {
            case .notFound: return "installer-not-found"
            case .noSpace: return "no-space"
            case .damaged: return "download-damaged"
            case .failed: return "download-failed"
            case .cancelled: return nil
            }
        }

        var text: String {
            switch self {
            case .notFound(let why), .noSpace(let why), .damaged(let why), .failed(let why): return why
            case .cancelled: return "cancelled"
            }
        }
    }

    private final class Job: @unchecked Sendable {
        let entry: InstallerCatalog.Entry
        var state = State.running
        var bytesDone: UInt64 = 0
        var bytesTotal: UInt64?
        var samples: [(time: TimeInterval, bytes: UInt64)] = []
        var path: String?
        var error: String?
        var code: String?
        var cancelRequested = false
        var task: URLSessionTask?
        init(entry: InstallerCatalog.Entry) { self.entry = entry }
    }

    private static let log = Logger(subsystem: "dev.openvm", category: "downloads")
    private static let keepFinished = 20

    private let environment: Environment
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var order: [String] = []

    init(environment: Environment) { self.environment = environment }

    // MARK: starting, watching, stopping

    /// Starts the download for an entry, or returns the one already running for it.
    func start(entry id: String) -> Result<String, TaskError> {
        guard let entry = environment.entries.first(where: { $0.id == id }), entry.kind == .linux,
            environment.indexURL(entry) != nil
        else {
            return .failure(.badArgument("openVM has no installer to download called \(id.debugDescription)"))
        }
        lock.lock()
        if let running = order.first(where: { jobs[$0]?.entry.id == id && jobs[$0]?.state == .running }) {
            lock.unlock()
            return .success(running)
        }
        let jobID = "iso-" + UUID().uuidString.lowercased()
        let job = Job(entry: entry)
        jobs[jobID] = job
        order.append(jobID)
        lock.unlock()
        Thread.detachNewThread { [self] in run(job) }
        return .success(jobID)
    }

    func status(_ id: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[id].map(snapshot)
    }

    /// The downloads that are running, for the quit dialog and the library.
    func running() -> [(id: String, snapshot: Snapshot)] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { id in
            guard let job = jobs[id], job.state == .running else { return nil }
            return (id, snapshot(job))
        }
    }

    private func snapshot(_ job: Job) -> Snapshot {
        var speed = 0.0
        if let first = job.samples.first, let last = job.samples.last, last.time > first.time {
            speed = Double(last.bytes - first.bytes) / (last.time - first.time)
        }
        return Snapshot(
            entry: job.entry.id, state: job.state, bytesDone: job.bytesDone, bytesTotal: job.bytesTotal,
            bytesPerSecond: job.state == .running ? speed : 0, path: job.path, error: job.error,
            code: job.code)
    }

    /// Stops a running download. What it has so far is kept, so starting again picks up from there.
    func cancel(_ id: String) -> Bool {
        lock.lock()
        guard let job = jobs[id], job.state == .running else {
            lock.unlock()
            return false
        }
        job.cancelRequested = true
        let task = job.task
        lock.unlock()
        task?.cancel()
        return true
    }

    // MARK: the cache

    private func prefix(_ entry: String) -> String { entry + "-" }

    /// The installers in the cache: finished ones, and the parts of unfinished downloads.
    func cached() -> [Cached] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.directory.path)) ?? []
        return names.sorted().compactMap { name in
            let complete = name.lowercased().hasSuffix(".iso")
            guard complete || name.hasSuffix(".iso.part") else { return nil }
            guard let entry = environment.entries.first(where: { name.hasPrefix(prefix($0.id)) }) else {
                return nil
            }
            let url = environment.directory.appendingPathComponent(name)
            let bytes =
                ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
                .uint64Value ?? 0
            let file = String(name.dropFirst(prefix(entry.id).count).dropLast(complete ? 0 : ".part".count))
            return Cached(entry: entry.id, file: file, path: url.path, bytes: bytes, complete: complete)
        }
    }

    /// Removes an entry's installer and any unfinished download of it. Returns how many bytes were freed.
    /// A download still running for it is stopped first.
    func remove(entry id: String) -> UInt64 {
        guard environment.entries.contains(where: { $0.id == id }) else { return 0 }
        lock.lock()
        let running = order.filter { jobs[$0]?.entry.id == id && jobs[$0]?.state == .running }
        lock.unlock()
        for job in running { _ = cancel(job) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, running.contains(where: { status($0)?.state == .running }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var freed: UInt64 = 0
        let names = (try? FileManager.default.contentsOfDirectory(atPath: environment.directory.path)) ?? []
        for name in names where name.hasPrefix(prefix(id)) {
            let url = environment.directory.appendingPathComponent(name)
            let bytes =
                ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?
                .uint64Value ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil { freed += bytes }
        }
        return freed
    }

    // MARK: one download

    private func run(_ job: Job) {
        do {
            let path = try download(job)
            finish(job) {
                $0.state = .done
                $0.path = path
            }
            Self.log.info("installer \(job.entry.id, privacy: .public) ready at \(path, privacy: .public)")
        } catch Failure.cancelled {
            finish(job) { $0.state = .cancelled }
        } catch let failure as Failure {
            Self.log.error(
                "installer \(job.entry.id, privacy: .public) failed: \(failure.text, privacy: .public)")
            finish(job) {
                $0.state = .failed
                $0.error = failure.text
                $0.code = failure.code
            }
        } catch {
            finish(job) {
                $0.state = .failed
                $0.error = "\(error)"
                $0.code = "download-failed"
            }
        }
    }

    private func finish(_ job: Job, _ change: (Job) -> Void) {
        lock.lock()
        change(job)
        job.task = nil
        let finished = order.filter { jobs[$0]?.state != .running }
        for id in finished.dropLast(Self.keepFinished) {
            jobs[id] = nil
            order.removeAll { $0 == id }
        }
        lock.unlock()
    }

    private func cancelled(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return job.cancelRequested
    }

    /// Resolves, downloads, verifies and puts the file in place. Returns the verified file's path.
    private func download(_ job: Job) throws -> String {
        let entry = job.entry
        guard let indexURL = environment.indexURL(entry) else {
            throw Failure.notFound("\(entry.name) has no index")
        }
        guard !environment.requireHTTPS || InstallerSources.allowed(indexURL) else {
            throw Failure.failed("the index for \(entry.name) is not on HTTPS: \(indexURL.absoluteString)")
        }
        // The index must come from the vendor's own host: a redirect to another host is refused.
        let index = try fetch(indexURL, job: job)
        guard let resolved = InstallerSources.resolve(entry.source, index: index, indexURL: indexURL) else {
            throw Failure.notFound("\(indexURL.absoluteString) lists no \(entry.name) installer for this Mac")
        }
        guard !environment.requireHTTPS || InstallerSources.allowed(resolved.url) else {
            throw Failure.failed("the installer is not on HTTPS: \(resolved.url.absoluteString)")
        }
        Self.log.info(
            "installer \(entry.id, privacy: .public): \(resolved.url.absoluteString, privacy: .public) sha256 \(resolved.sha256, privacy: .public)"
        )

        try FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        let final = environment.directory.appendingPathComponent(prefix(entry.id) + resolved.fileName)
        let part = final.appendingPathExtension("part")
        let marker = final.appendingPathExtension("sha256")
        // Already downloaded and verified against this very hash: nothing to do.
        if FileManager.default.fileExists(atPath: final.path),
            (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(
                in: .whitespacesAndNewlines) == resolved.sha256
        {
            return final.path
        }

        let have =
            ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.uint64Value
            ?? 0
        let expected = resolved.size ?? UInt64(entry.downloadGB * 1_000_000_000)
        let remaining = expected > have ? expected - have : 0
        // Room for the rest of the download and for the new VM's disk beside it.
        let forDisk = UInt64(max(0, Double(entry.neededGB) - entry.downloadGB) * Double(1 << 30))
        let free = environment.freeBytes()
        guard free >= remaining + forDisk else {
            throw Failure.noSpace(
                "\(entry.name) needs \((remaining + forDisk) >> 30) GB free for the download and a virtual machine; this Mac has \(free >> 30) GB"
            )
        }

        try receive(resolved.url, into: part, from: have, expected: resolved.size, job: job)
        if cancelled(job) { throw Failure.cancelled }

        let size =
            ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.uint64Value
            ?? 0
        let hash = try Self.sha256(of: part)
        Self.log.info(
            "installer \(entry.id, privacy: .public): \(size) bytes, sha256 \(hash, privacy: .public)")
        if let wanted = resolved.size, wanted != size {
            // A short file after a clean end is a cut-off download; keep it, so the rest can be fetched.
            if size < wanted { throw Failure.failed("the download stopped at \(size) of \(wanted) bytes") }
        }
        guard hash == resolved.sha256 else {
            try? FileManager.default.removeItem(at: part)
            throw Failure.damaged(
                "expected SHA-256 \(resolved.sha256), got \(hash) (\(size) bytes from \(resolved.url.absoluteString))"
            )
        }
        if let problem = environment.check(part) {
            try? FileManager.default.removeItem(at: part)
            throw Failure.damaged(problem)
        }
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: part, to: final)
            try Data(resolved.sha256.utf8).write(to: marker, options: .atomic)
        } catch {
            throw Failure.failed("could not put the installer in place: \(error)")
        }
        return final.path
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: HTTP

    /// Fetches a small file (an index). A redirect is followed only to one of the vendor's own hosts.
    private func fetch(_ url: URL, job: Job) throws -> Data {
        let hosts = Set(environment.indexHosts(job.entry) + [url.host].compactMap { $0 })
        let receiver = Receiver(
            file: nil, offset: 0, requireHTTPS: environment.requireHTTPS, allowedHosts: hosts, limit: 8 << 20)
        try perform(URLRequest(url: url), receiver: receiver, job: job)
        guard receiver.status == 200 else {
            throw receiver.status == 404
                ? Failure.notFound("\(url.absoluteString) answered 404")
                : Failure.failed("\(url.absoluteString) answered \(receiver.status)")
        }
        return receiver.body
    }

    /// Downloads into `part`, asking for the rest when `have` bytes are already there.
    private func receive(_ url: URL, into part: URL, from have: UInt64, expected: UInt64?, job: Job) throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw Failure.failed("could not create \(part.path)")
            }
        }
        if let expected, have == expected { return }  // all there already: verify it
        let handle: FileHandle
        do { handle = try FileHandle(forWritingTo: part) } catch {
            throw Failure.failed("could not open \(part.path): \(error)")
        }
        defer { try? handle.close() }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let receiver = Receiver(
            file: handle, offset: have, requireHTTPS: environment.requireHTTPS, allowedHosts: nil, limit: nil)
        receiver.progress = { [weak self, weak job] done, total in
            guard let self, let job else { return }
            self.lock.lock()
            job.bytesDone = done
            job.bytesTotal = total ?? expected
            let now = Date().timeIntervalSinceReferenceDate
            job.samples.append((now, done))
            while let first = job.samples.first, now - first.time > 4, job.samples.count > 2 {
                job.samples.removeFirst()
            }
            self.lock.unlock()
        }
        receiver.progress?(have, expected)
        try perform(request, receiver: receiver, job: job)
        Self.log.info(
            "installer \(job.entry.id, privacy: .public): HTTP \(receiver.status) from \(receiver.finalHost ?? "?", privacy: .public), \(receiver.received) bytes"
        )
        switch receiver.status {
        case 200, 206: break
        case 416: break  // nothing left to send: the part is whole, and the hash decides
        case 404: throw Failure.notFound("\(url.absoluteString) answered 404")
        default: throw Failure.failed("\(url.absoluteString) answered \(receiver.status)")
        }
        if let problem = receiver.writeProblem { throw Failure.failed(problem) }
    }

    private func perform(_ request: URLRequest, receiver: Receiver, job: Job) throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        lock.lock()
        let stop = job.cancelRequested
        job.task = task
        lock.unlock()
        if stop { throw Failure.cancelled }
        task.resume()
        receiver.done.wait()
        if cancelled(job) { throw Failure.cancelled }
        if let refused = receiver.refused { throw Failure.failed(refused) }
        if let error = receiver.error { throw Failure.failed(error.localizedDescription) }
    }
}

/// Takes one HTTP response: into memory (an index) or onto the end of a file (an installer).
private nonisolated final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let file: FileHandle?
    private var offset: UInt64
    private let requireHTTPS: Bool
    /// Where a redirect may lead. Nil: anywhere (an installer may come from a mirror; its hash is checked).
    private let allowedHosts: Set<String>?
    private let limit: Int?
    var progress: ((UInt64, UInt64?) -> Void)?
    private(set) var status = 0
    private(set) var body = Data()
    private(set) var received: UInt64 = 0
    private(set) var error: Error?
    private(set) var refused: String?
    private(set) var writeProblem: String?
    private(set) var finalHost: String?
    private var total: UInt64?

    init(file: FileHandle?, offset: UInt64, requireHTTPS: Bool, allowedHosts: Set<String>?, limit: Int?) {
        self.file = file
        self.offset = offset
        self.requireHTTPS = requireHTTPS
        self.allowedHosts = allowedHosts
        self.limit = limit
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else { return completionHandler(nil) }
        if requireHTTPS, !InstallerSources.allowed(url) {
            refused = "refused a redirect off HTTPS, to \(url.absoluteString)"
            return completionHandler(nil)
        }
        if let allowedHosts, !allowedHosts.contains(url.host ?? "") {
            refused = "refused a redirect to another host, \(url.host ?? "?")"
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode ?? 0
        finalHost = response.url?.host
        guard status == 200 || status == 206 else { return completionHandler(.cancel) }
        if let file {
            // 200 means the server sent the whole file, not the rest: start the part again.
            if status == 200, offset > 0 {
                do { try file.truncate(atOffset: 0) } catch {
                    writeProblem = "could not restart the download: \(error)"
                }
                offset = 0
            }
            do { try file.seek(toOffset: offset) } catch {
                writeProblem = "could not write the download: \(error)"
            }
        }
        if response.expectedContentLength >= 0 { total = offset + UInt64(response.expectedContentLength) }
        progress?(offset, total)
        completionHandler(writeProblem == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += UInt64(data.count)
        if let file {
            do { try file.write(contentsOf: data) } catch {
                // A full disk shows here.
                writeProblem = "could not write the download: \(error.localizedDescription)"
                dataTask.cancel()
                return
            }
            progress?(offset + received, total)
        } else {
            body.append(data)
            if let limit, body.count > limit {
                refused = "the index is larger than \(limit) bytes"
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A response refused above, or a write that failed, ends as a cancel: those say why themselves.
        let stoppedByUs =
            (error as? URLError)?.code == .cancelled && (status != 0 || refused != nil || writeProblem != nil)
        if !stoppedByUs { self.error = error }
        done.signal()
    }
}

// MARK: the host's own downloads, and the ops

nonisolated let installerDownloads = InstallerDownloads(
    environment: InstallerDownloads.Environment(
        directory: OVMPaths.isos,
        freeBytes: { freeDiskMB(at: home) << 20 },
        check: { file in
            let size =
                ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?
                .uint64Value ?? 0
            return LinuxISOCheck.sizeProblem(bytes: size) ?? inspectLinuxISO(file).problem
        }))

/// A download's status, as `task-status` answers it. `progress` is a line for the command line.
nonisolated func downloadStatusFields(_ snapshot: InstallerDownloads.Snapshot) -> [(key: String, value: CBOR)]
{
    var fields: [(key: String, value: CBOR)] = [
        ("state", .text(snapshot.state.rawValue)), ("entry", .text(snapshot.entry)),
        ("bytesDone", .uint(snapshot.bytesDone)),
        ("bytesPerSecond", .uint(UInt64(max(0, snapshot.bytesPerSecond)))),
    ]
    var line = "\(snapshot.bytesDone >> 20) MB"
    if let total = snapshot.bytesTotal {
        fields.append(("bytesTotal", .uint(total)))
        line += " of \(total >> 20) MB"
    }
    fields.append(("progress", .text(line)))
    if let path = snapshot.path { fields.append(("path", .text(path))) }
    if let error = snapshot.error { fields.append(("error", .text(error))) }
    if let code = snapshot.code { fields.append(("code", .text(code))) }
    return fields
}

/// The installer cache and the downloads in flight, for the library, Settings and `openvmctl installer list`.
nonisolated func installersListOp(_ r: VmRequest) throws -> Envelope {
    let running = installerDownloads.running()
    let rows: [CBOR] = installerDownloads.cached().map { item in
        var row: [(key: String, value: CBOR)] = [
            ("entry", .text(item.entry)), ("file", .text(item.file)), ("path", .text(item.path)),
            ("bytes", .uint(item.bytes)), ("complete", .bool(item.complete)),
        ]
        if let name = InstallerCatalog.entry(item.entry)?.name { row.append(("name", .text(name))) }
        if !item.complete, let job = running.first(where: { $0.snapshot.entry == item.entry }) {
            row.append(("taskId", .text(job.id)))
            if let total = job.snapshot.bytesTotal { row.append(("bytesTotal", .uint(total))) }
            row.append(("bytesPerSecond", .uint(UInt64(max(0, job.snapshot.bytesPerSecond)))))
        }
        return .map(row)
    }
    return r.ok([("installers", .array(rows)), ("directory", .text(OVMPaths.isos.path))])
}

nonisolated func installerRemoveOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let entry)? = r.arg("entry"), InstallerCatalog.entry(entry) != nil else {
        return r.fail("installer-remove needs an entry from the catalog")
    }
    // An installer a VM still starts from is not removed from under it.
    let inUse = (try registry.list()).filter { record in
        guard let media = record.installMediaPath else { return false }
        return URL(fileURLWithPath: media).deletingLastPathComponent().standardizedFileURL.path
            == OVMPaths.isos.standardizedFileURL.path
            && URL(fileURLWithPath: media).lastPathComponent.hasPrefix(entry + "-")
    }
    if let user = inUse.first {
        return r.fail(
            "\(user.name) still starts from this installer: remove the installer from it first (Eject Installer)"
        )
    }
    return r.ok([("freedBytes", .uint(installerDownloads.remove(entry: entry)))])
}
