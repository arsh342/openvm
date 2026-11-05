// Transfers — the commands that take many requests: file transfer and drops.
import Foundation
import OpenVMCore

struct FileCommand {
    let mode: String
    let vmID: String
    let guestName: String
    let hostURL: URL
}

func validGuestName(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240 else { return false }
    return name.utf8.allSatisfy {
        ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95
            || $0 == 45
    }
}

func fileRequest(
    _ command: FileCommand, op: String,
    fields: [(key: String, value: CBOR)]
) throws -> [(key: String, value: CBOR)] {
    let reply = try daemonRequest("file-\(op)", args: [("id", .text(command.vmID))] + fields)
    return try resultFields(reply)
}

struct DropCommand {
    let vmID: String
    let paths: [String]
}

/// Starts the drop, then polls: the copy runs in the guest, for as long as it takes.
func runDrop(_ command: DropCommand) throws -> String {
    _ = try resultFields(
        try daemonRequest(
            "drag",
            args: [
                ("id", .text(command.vmID)), ("op", .text("drop")),
                ("paths", .array(command.paths.map { .text($0) })),
            ]))
    while true {
        let result = try resultFields(
            try daemonRequest(
                "drag",
                args: [
                    ("id", .text(command.vmID)), ("op", .text("status")),
                ]))
        guard let status = DragDrop.status(.map(result)) else {
            throw CLIError.protocolFailure("guest drag status was not understood")
        }
        if status.done {
            if let error = status.error { throw CLIError.remote("drop failed: \(error)") }
            return "dropped \(status.placed.joined(separator: ", ")) (\(status.bytes) bytes)"
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

func transferFile(_ command: FileCommand) throws -> String {
    let chunkLimit = 65_536
    let maxSize: UInt64 = 1 << 30
    if command.mode == "push" {
        let attrs = try FileManager.default.attributesOfItem(atPath: command.hostURL.path)
        guard let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
            attrs[.type] as? FileAttributeType == .typeRegular
        else {
            throw CLIError.remote("host source is not a regular file")
        }
        guard fileSize <= maxSize else { throw CLIError.remote("file exceeds the 1 GiB transfer limit") }
        let input = try FileHandle(forReadingFrom: command.hostURL)
        defer { try? input.close() }
        let transferID = UUID().uuidString.lowercased()
        var offset: UInt64 = 0
        do {
            while true {
                let remaining = fileSize - offset
                let requested = Int(min(UInt64(chunkLimit), remaining))
                let data = try input.read(upToCount: requested) ?? Data()
                guard data.count == requested else {
                    throw CLIError.remote("host source changed while it was being read")
                }
                let eof = offset + UInt64(data.count) == fileSize
                let result = try fileRequest(
                    command, op: "write",
                    fields: [
                        ("op", .text("write")), ("name", .text(command.guestName)),
                        ("transferId", .text(transferID)), ("offset", .uint(offset)),
                        ("data", .bytes(data)), ("eof", .bool(eof)),
                    ])
                guard case .uint(let next)? = field(result, "offset"),
                    next == offset + UInt64(data.count),
                    case .bool(let confirmedEOF)? = field(result, "eof"), confirmedEOF == eof
                else {
                    throw CLIError.protocolFailure("guest acknowledged an unexpected file offset")
                }
                offset = next
                if eof { break }
                guard offset < maxSize else { throw CLIError.remote("file exceeds the 1 GiB transfer limit") }
            }
        } catch {
            _ = try? fileRequest(
                command, op: "abort",
                fields: [
                    ("op", .text("abort")), ("name", .text(command.guestName)),
                    ("transferId", .text(transferID)),
                ])
            throw error
        }
        return "copied \(offset) bytes to guest /tmp/openvm-share/\(command.guestName)"
    }

    let parent = command.hostURL.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path) else {
        throw CLIError.remote("host destination directory does not exist")
    }
    let temporary = parent.appendingPathComponent(".openvm-\(UUID().uuidString).part")
    guard FileManager.default.createFile(atPath: temporary.path, contents: Data()) else {
        throw CLIError.remote("could not create temporary host destination")
    }
    var committed = false
    defer { if !committed { try? FileManager.default.removeItem(at: temporary) } }
    let output = try FileHandle(forWritingTo: temporary)
    defer { try? output.close() }
    var offset: UInt64 = 0
    while true {
        let result = try fileRequest(
            command, op: "read",
            fields: [
                ("op", .text("read")), ("name", .text(command.guestName)),
                ("offset", .uint(offset)), ("length", .uint(UInt64(chunkLimit))),
            ])
        guard case .uint(let next)? = field(result, "offset"),
            case .bytes(let data)? = field(result, "data"), data.count <= chunkLimit,
            case .bool(let eof)? = field(result, "eof"), next == offset + UInt64(data.count),
            eof || !data.isEmpty
        else {
            throw CLIError.protocolFailure("guest returned an invalid file chunk")
        }
        guard next <= maxSize else { throw CLIError.remote("guest file exceeds the 1 GiB transfer limit") }
        try output.write(contentsOf: data)
        offset = next
        if eof { break }
    }
    try output.synchronize()
    try output.close()
    guard rename(temporary.path, command.hostURL.path) == 0 else {
        throw CLIError.remote("could not commit host file: \(String(cString: strerror(errno)))")
    }
    committed = true
    return "copied \(offset) bytes from guest /tmp/openvm-share/\(command.guestName)"
}
