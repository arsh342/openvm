// InstallerRow — one file in openVM's installer cache, as the host lists it: a finished installer, or
// the part of a download that is running or was stopped.
import Foundation
import OpenVMCore

struct InstallerRow: Equatable, Identifiable {
    let entry: String
    let name: String
    let file: String
    let path: String
    let bytes: UInt64
    /// False for a download that has not finished.
    let complete: Bool
    /// The download's task, while it is running.
    let taskId: String?
    let bytesTotal: UInt64?
    let bytesPerSecond: UInt64

    var id: String { path }
    var downloading: Bool { taskId != nil }

    init?(row: CBOR) {
        guard case .map(let fields) = row else { return nil }
        func text(_ key: String) -> String? {
            if case .text(let value)? = fields.first(where: { $0.key == key })?.value { return value }
            return nil
        }
        func number(_ key: String) -> UInt64? {
            if case .uint(let value)? = fields.first(where: { $0.key == key })?.value { return value }
            return nil
        }
        guard let entry = text("entry"), let file = text("file"), let path = text("path") else { return nil }
        self.entry = entry
        self.file = file
        self.path = path
        name = text("name") ?? entry
        bytes = number("bytes") ?? 0
        complete = fields.first(where: { $0.key == "complete" })?.value == .bool(true)
        taskId = text("taskId")
        bytesTotal = number("bytesTotal")
        bytesPerSecond = number("bytesPerSecond") ?? 0
    }
}

/// How a download is going, in words: "1.2 GB of 3.9 GB · 12 MB per second · about 4 minutes left".
enum DownloadText {
    static func size(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func progress(done: UInt64, total: UInt64?, bytesPerSecond: UInt64) -> String {
        guard let total, total > 0 else { return size(done) }
        var parts = ["\(size(done)) of \(size(total))"]
        if bytesPerSecond > 0 {
            parts.append("\(size(bytesPerSecond)) per second")
            parts.append(remaining(seconds: Double(total > done ? total - done : 0) / Double(bytesPerSecond)))
        }
        return parts.joined(separator: " · ")
    }

    static func remaining(seconds: Double) -> String {
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "about 1 minute left" : "about \(minutes) minutes left" }
        let hours = Int((seconds / 3600).rounded())
        return hours == 1 ? "about 1 hour left" : "about \(hours) hours left"
    }

    /// 0 to 1, or nil when the total is not known yet.
    static func fraction(done: UInt64, total: UInt64?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }
}
