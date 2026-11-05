// PrinterBridge — the host end of guest printing.
//
// The host stays the only opener of the channel (docs/guest-protocol.md frame rule 5),
// so a guest never pushes a job: it leaves finished PDFs in its spool and this
// loop collects them. Publishing the host's printers rides the same loop.
//
//     every 3 s, per running VM:  publish if the list changed, then collect
//
// Nothing here runs on the main actor: a channel exchange blocks on a VZ
// callback delivered there (see GuestChannel.offMainActor).
import Foundation
import OpenVMCore

nonisolated final class PrinterBridge: @unchecked Sendable {
    struct Published: Equatable {
        var printers: [String]
        var defaultPrinter: String?
    }

    /// Belongs to one boot, not one VM record: a restarted guest gets everything
    /// again, because a queue created just before a stop may never have reached
    /// the guest's disk.
    private struct VMState {
        let boot: UUID
        var published: Published?
        var retryAt = Date.distantPast
        var lastError: String?
    }

    private let tick: TimeInterval = 3
    private let hostScanEvery: TimeInterval = 30
    private let retryAfter: TimeInterval = 15
    private let jobsPerTick = 8

    private var host = Published(printers: [], defaultPrinter: nil)
    private var hostScannedAt = Date.distantPast
    private var vms: [String: VMState] = [:]

    private let lp: String
    private let lpstat: String
    private let failedDir: URL

    init(home: URL) {
        let env = ProcessInfo.processInfo.environment
        lp = env["OPENVM_LP"] ?? "/usr/bin/lp"
        lpstat = env["OPENVM_LPSTAT"] ?? "/usr/bin/lpstat"
        failedDir = home.appendingPathComponent("printjobs")
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                pass()
                Thread.sleep(forTimeInterval: tick)
            }
        }
    }

    private func pass() {
        guard let records = try? registry.list() else { return }
        let running = records.filter { $0.state == .running && liveVMs.peek($0.uuid) != nil }
        // By live machine, not by `running`: a suspended guest keeps its queues, and
        // forgetting them made every resume re-run a sync that holds the agent.
        vms = vms.filter { liveVMs.peek($0.key) != nil }
        guard !running.isEmpty else { return }
        if Date().timeIntervalSince(hostScannedAt) >= hostScanEvery { scanHost() }
        for record in running {
            guard let guest = liveVMs.peek(record.uuid) else { continue }
            serve(record, guest)
        }
    }

    private func serve(_ record: VmRecord, _ guest: LiveGuest) {
        let boot = guest.boot
        var state = vms[record.uuid].flatMap { $0.boot == boot ? $0 : nil } ?? VMState(boot: boot)
        defer { vms[record.uuid] = state }
        guard Date() >= state.retryAt else { return }
        do {
            if state.published != host {
                guard try publish(host, to: guest) else { return }
                state.published = host
                note("openvmd: \(record.name): published \(host.printers.count) printer(s)")
            }
            // A guest with no queues has nothing to collect; a host with no
            // printers costs one exchange per boot, not one every tick.
            if !host.printers.isEmpty { try collect(record, guest) }
            if state.lastError != nil { note("openvmd: \(record.name): printing channel recovered") }
            state.lastError = nil
        } catch {
            // Each new reason is worth a line; the same one every retry is not.
            let reason = "\(error)"
            if state.lastError != reason { note("openvmd: \(record.name): printing unavailable: \(reason)") }
            state.lastError = reason
            state.retryAt = Date().addingTimeInterval(retryAfter)
        }
    }

    /// False while the guest is still working on it; the next tick asks again.
    private func publish(_ list: Published, to guest: LiveGuest) throws -> Bool {
        var body: [(key: String, value: CBOR)] = [
            ("op", .text("sync")),
            ("printers", .array(list.printers.map { .text($0) })),
        ]
        if let name = list.defaultPrinter { body.append(("default", .text(name))) }
        return !Printing.syncIsPending(try GuestChannel.printer(guest, body: .map(body), timeoutSeconds: 60))
    }

    private func collect(_ record: VmRecord, _ guest: LiveGuest) throws {
        let reply = try GuestChannel.printer(guest, body: .map([("op", .text("jobs"))]))
        for job in Printing.parseJobs(reply).prefix(jobsPerTick) {
            if let why = Printing.refusal(job, allowed: host.printers) {
                note("openvmd: \(record.name): dropped job \(job.job): it \(why)")
                try release(job, guest)
            } else {
                try take(job, record, guest)
            }
        }
    }

    private func release(_ job: GuestPrintJob, _ guest: LiveGuest) throws {
        _ = try GuestChannel.printer(guest, body: .map([("op", .text("done")), ("job", .text(job.job))]))
    }

    /// Copies one job out of the guest and hands it to CUPS. The guest gives the
    /// job up before lp runs: paper cannot be taken back, so a guest that vanishes
    /// mid-way must mean "not printed yet", never "printed twice". From then on
    /// the host's copy is the job, kept under $OPENVM_HOME/printjobs if lp fails.
    private func take(_ job: GuestPrintJob, _ record: VmRecord, _ guest: LiveGuest) throws {
        let dir = failedDir.appendingPathComponent(record.uuid)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(job.job)
        FileManager.default.createFile(
            atPath: file.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: file)
        var head = Data()
        var offset: UInt64 = 0
        do {
            defer { try? out.close() }
            while offset < job.size {
                let reply = try GuestChannel.printer(
                    guest,
                    body: .map([
                        ("op", .text("fetch")), ("job", .text(job.job)), ("offset", .uint(offset)),
                        ("length", .uint(min(Printing.chunkBytes, job.size - offset))),
                    ]))
                guard case .map(let fields) = reply,
                    case .bytes(let data)? = fields.first(where: { $0.key == "data" })?.value,
                    !data.isEmpty, UInt64(data.count) <= job.size - offset
                else {
                    throw GuestBootError.failure("guest sent a bad chunk of \(job.job)")
                }
                if head.count < 8 { head.append(data.prefix(8)) }
                try out.write(contentsOf: data)
                offset += UInt64(data.count)
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        guard Printing.isPDF(head) else {
            try? FileManager.default.removeItem(at: file)
            note("openvmd: \(record.name): dropped job \(job.job): not a PDF")
            try release(job, guest)
            return
        }
        do {
            try release(job, guest)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        do {
            _ = try run(lp, ["-d", job.printer, "-t", "\(record.name): \(job.job)", file.path])
            try? FileManager.default.removeItem(at: file)
            note("openvmd: \(record.name): spooled \(job.job) (\(job.size) bytes) to \(job.printer)")
        } catch {
            note("openvmd: \(record.name): could not spool \(job.job), kept at \(file.path): \(error)")
        }
    }

    private func scanHost() {
        hostScannedAt = Date()
        do {
            let names = Printing.parseDestinations(try run(lpstat, ["-e"]))
            // lpstat exits non-zero when no default is set; that is not an error.
            let fallback = (try? run(lpstat, ["-d"])) ?? ""
            host = Published(printers: names, defaultPrinter: Printing.parseDefault(fallback))
        } catch {
            note("openvmd: could not list host printers: \(error)")
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GuestBootError.failure("\(tool) exited \(process.terminationStatus): \(text)")
        }
        return text
    }
}
