// WindowsInstallMedia — the host side of the WinPE install (tools/windows/install.cmd).
//
// The install boot attaches the media built by tools/build/mk-windows-media.sh as a
// second disk. WinPE installs onto the first disk and records "OK" or "FAIL"
// in \openvm\result on the media's data volume (the one with \openvm\media.tag),
// with its log beside it, then shuts down. Once the VM has stopped, the host
// attaches the media read-only and reads that result.
import Foundation

nonisolated enum WindowsInstallMedia {
    struct Result {
        let ok: Bool
        let log: String
    }

    enum Failure: Error, CustomStringConvertible {
        case attach(String)
        case noDataVolume
        var description: String {
            switch self {
            case .attach(let m): return "could not attach the install media: \(m)"
            case .noDataVolume: return "the install media has no volume carrying openvm/media.tag"
            }
        }
    }

    /// Attach a raw image read-only, run `body` with its mount points, detach.
    static func withAttached<T>(_ image: URL, _ body: ([URL]) throws -> T) throws -> T {
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = [
            "attach", "-readonly", "-nobrowse", "-noverify",
            "-imagekey", "diskimage-class=CRawDiskImage", image.path,
        ]
        let out = Pipe()
        attach.standardOutput = out
        attach.standardError = Pipe()
        try attach.run()
        attach.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard attach.terminationStatus == 0 else { throw Failure.attach(text) }
        // Lines are "<dev>\t<content>\t<mount point>"; the first line is the whole disk.
        let lines = text.split(separator: "\n").map {
            $0.split(separator: "\t", omittingEmptySubsequences: false)
        }
        let wholeDisk = lines.first.flatMap { $0.first }.map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        let mounts = lines.compactMap { fields -> URL? in
            guard fields.count >= 3 else { return nil }
            let path = fields[2].trimmingCharacters(in: .whitespaces)
            return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        defer {
            if let wholeDisk {
                let detach = Process()
                detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                detach.arguments = ["detach", wholeDisk, "-quiet"]
                try? detach.run()
                detach.waitUntilExit()
            }
        }
        return try body(mounts)
    }

    /// The install's recorded outcome. A media without a result file means the
    /// script never got that far (the VM died, or WinPE did not run it).
    static func readResult(_ media: URL) throws -> Result {
        try withAttached(media) { mounts in
            guard
                let data = mounts.first(where: {
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("openvm/media.tag").path)
                })
            else { throw Failure.noDataVolume }
            let result =
                (try? String(contentsOf: data.appendingPathComponent("openvm/result"), encoding: .utf8)) ?? ""
            let log =
                (try? String(
                    contentsOf: data.appendingPathComponent("openvm/install.log"), encoding: .isoLatin1))
                ?? "(no install log on the media)"
            return Result(ok: result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK", log: log)
        }
    }
}
