// WindowsISO — looking inside the Windows ISO a person chose, before a long build starts: is it
// an ISO, is it Windows, is it ARM64, does it carry install.wim. It is mounted read-only, a
// few file names are read, and it is detached again.
import Foundation
import OpenVMCore

nonisolated enum WindowsISOError: Error, CustomStringConvertible {
    case notAnISO(String)
    case cannotMount(String)

    var description: String {
        switch self {
        case .notAnISO(let why), .cannotMount(let why): return why
        }
    }
}

/// The ISO file a client named, or why it is not acceptable. It must be an absolute path to an
/// existing regular file whose name ends in .iso: the path ends up as an argument to the media
/// script, so nothing else is let through.
nonisolated func validISOPath(_ path: String) -> Result<URL, WindowsISOError> {
    guard path.hasPrefix("/"), path.lowercased().hasSuffix(".iso") else {
        return .failure(.notAnISO("choose an ISO file: an absolute path ending in .iso"))
    }
    let url = URL(fileURLWithPath: path)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
    guard (attributes?[.type] as? FileAttributeType) == .typeRegular else {
        return .failure(.notAnISO("\(url.lastPathComponent) is not a file that exists"))
    }
    return .success(url)
}

/// The names the verdict looks at, lower-cased and relative to the ISO's root: its top level, and
/// what is in `efi/boot` and `sources`. A directory may be spelled in any letter case on disk.
nonisolated func windowsMediaFiles(at root: URL) -> Set<String> {
    func children(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }
    var files = Set<String>()
    let top = children(root)
    for name in top { files.insert(name.lowercased()) }
    for name in top where name.lowercased() == "sources" {
        for child in children(root.appendingPathComponent(name)) { files.insert("sources/\(child.lowercased())") }
    }
    for name in top where name.lowercased() == "efi" {
        for sub in children(root.appendingPathComponent(name)) where sub.lowercased() == "boot" {
            for child in children(root.appendingPathComponent(name).appendingPathComponent(sub)) {
                files.insert("efi/boot/\(child.lowercased())")
            }
        }
    }
    return files
}

/// Mounts an ISO read-only, decides whether it is usable, and detaches it. nil means usable.
nonisolated func inspectWindowsISO(_ iso: URL) throws -> MediaProblem? {
    let attach = Process()
    attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    attach.arguments = ["attach", "-nobrowse", "-readonly", "-noverify", "-plist", iso.path]
    let out = Pipe()
    attach.standardOutput = out
    attach.standardError = FileHandle.nullDevice
    do { try attach.run() } catch { throw WindowsISOError.cannotMount("could not run hdiutil: \(error)") }
    // Read before waiting: a full pipe would otherwise stop hdiutil.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    attach.waitUntilExit()
    guard attach.terminationStatus == 0,
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let entities = plist["system-entities"] as? [[String: Any]]
    else {
        throw WindowsISOError.cannotMount("macOS could not open \(iso.lastPathComponent) as a disk image")
    }
    let device = entities.compactMap { $0["dev-entry"] as? String }.first
    defer {
        if let device {
            let detach = Process()
            detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            detach.arguments = ["detach", device, "-quiet", "-force"]
            detach.standardOutput = FileHandle.nullDevice
            detach.standardError = FileHandle.nullDevice
            try? detach.run()
            detach.waitUntilExit()
        }
    }
    guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
        throw WindowsISOError.cannotMount("\(iso.lastPathComponent) mounted with no readable volume")
    }
    return WindowsMediaCheck.problem(files: windowsMediaFiles(at: URL(fileURLWithPath: mount)))
}

nonisolated func windowsISOCheckOp(_ r: VmRequest) throws -> Envelope {
    guard case .text(let path)? = r.arg("iso") else { return r.fail("windows-iso-check needs an iso") }
    switch validISOPath(path) {
    case .failure(let error): return r.fail(error.description)
    case .success(let url):
        do {
            let problem = try inspectWindowsISO(url)
            var fields: [(key: String, value: CBOR)] = [("usable", .bool(problem == nil))]
            if let problem { fields.append(("problem", .text(problem.description))) }
            return r.ok(fields)
        } catch {
            return r.fail("\(error)")
        }
    }
}
