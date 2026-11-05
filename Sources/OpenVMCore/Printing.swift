// The host side of guest printing: parsing lpstat and deciding which jobs to accept.
import Foundation

/// The host side of guest printing: what `lpstat` says, and what
/// may be believed about a job a guest hands over.
///
/// A guest is untrusted. Everything in `GuestPrintJob` came from it, so a job
/// is only spooled once its name, printer and bytes have passed these checks.
public nonisolated enum Printing {
    /// A guest whose sync is still running says so, and the host asks again.
    public static func syncIsPending(_ reply: CBOR) -> Bool {
        guard case .map(let fields) = reply,
            case .bool(true)? = fields.first(where: { $0.key == "pending" })?.value
        else { return false }
        return true
    }

    /// A job larger than this is dropped, not spooled.
    public static let maxJobBytes: UInt64 = 256 << 20
    /// One `fetch` reply carries at most this much (the guest file chunk size).
    public static let chunkBytes: UInt64 = 65_536

    /// CUPS queue names as the guest may be told them. The name reaches a guest
    /// shell or PowerShell argument, so the alphabet is deliberately narrow.
    public static func validPrinterName(_ name: String) -> Bool {
        validToken(name, maxLength: 96)
    }

    /// A spool file name, chosen by the guest and used as a host file name.
    public static func validJobName(_ name: String) -> Bool {
        validToken(name, maxLength: 160)
    }

    private static func validToken(_ value: String, maxLength: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxLength, value.first != ".", value.first != "-" else {
            return false
        }
        return value.utf8.allSatisfy { c in
            (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || (c >= 0x30 && c <= 0x39)
                || c == 0x2e || c == 0x5f || c == 0x2d
        }
    }

    /// `lpstat -e`: one destination per line. An `instance` of a queue
    /// ("queue/draft") is not a queue of its own and is skipped, as is any name
    /// the guest could not be handed safely.
    public static func parseDestinations(_ output: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard validPrinterName(name), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    /// `lpstat -d` under LC_ALL=C: "system default destination: NAME", or
    /// "no system default destination".
    public static func parseDefault(_ output: String) -> String? {
        let prefix = "system default destination: "
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let name = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return validPrinterName(name) ? name : nil
        }
        return nil
    }

    /// The `jobs` reply. An entry that does not parse is left out: it can only
    /// come from a broken or hostile guest, and the rest may still be good.
    public static func parseJobs(_ reply: CBOR) -> [GuestPrintJob] {
        guard case .map(let fields) = reply,
            case .array(let rows)? = fields.first(where: { $0.key == "jobs" })?.value
        else { return [] }
        return rows.compactMap { row in
            guard case .map(let entry) = row,
                case .text(let job)? = entry.first(where: { $0.key == "job" })?.value,
                case .text(let printer)? = entry.first(where: { $0.key == "printer" })?.value,
                case .uint(let size)? = entry.first(where: { $0.key == "size" })?.value,
                validJobName(job)
            else { return nil }
            return GuestPrintJob(job: job, printer: printer, size: size)
        }
    }

    /// Why a job must not be spooled, or nil if it may be.
    public static func refusal(_ job: GuestPrintJob, allowed: [String]) -> String? {
        guard allowed.contains(job.printer) else {
            return "names unpublished printer \(job.printer.debugDescription)"
        }
        guard job.size > 0 else { return "is empty" }
        guard job.size <= maxJobBytes else { return "is \(job.size) bytes, over the limit" }
        return nil
    }

    /// The guest queues render to PDF, so anything else is not a job of ours.
    public static func isPDF(_ head: Data) -> Bool {
        head.starts(with: Array("%PDF-".utf8))
    }
}

/// A finished print job waiting in a guest's spool.
public nonisolated struct GuestPrintJob: Sendable, Equatable {
    public let job: String
    public let printer: String
    public let size: UInt64

    public init(job: String, printer: String, size: UInt64) {
        self.job = job
        self.printer = printer
        self.size = size
    }
}
