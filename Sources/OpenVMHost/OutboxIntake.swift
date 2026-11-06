// OutboxIntake — takes the files a guest has put in its outbox and moves them to the Mac.
//
// The protocol is small. The guest tool builds a set in a hidden folder, `.incoming-<id>`, writes
// `.ready` (the names of the top-level items, one per line) as the last file, and renames the folder
// to `<id>`. A rename is one event on the outbox, so nothing here polls, and a set without `.ready`
// is never taken. The guest is untrusted: OutboxRules vets every name and entry first, and a set that
// fails is deleted whole.
import Darwin
import Foundation
import OpenVMCore

nonisolated enum OutboxIntake {
    enum Result: Equatable {
        case received([String])
        case rejected(String)
    }

    /// The marker file the guest writes last.
    static let readyName = ".ready"

    /// Handles every complete set in `outbox`; returns one result per set, in name order.
    static func collect(outbox: URL, into destination: URL, maxBytes: UInt64) -> [Result] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: outbox.path) else { return [] }
        var results: [Result] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let set = outbox.appendingPathComponent(name)
            var info = stat()
            guard lstat(set.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                try? fm.removeItem(at: set)  // anything but a folder does not belong here
                continue
            }
            // No mark yet: the guest may still be writing. (A set renamed into place has it.)
            guard let manifest = try? String(contentsOf: set.appendingPathComponent(readyName), encoding: .utf8)
            else { continue }
            results.append(take(set: set, manifest: manifest, into: destination, maxBytes: maxBytes))
            try? fm.removeItem(at: set)
        }
        return results
    }

    private static func take(set: URL, manifest: String, into destination: URL, maxBytes: UInt64) -> Result {
        switch OutboxRules.vet(manifest: manifest, root: set, maxBytes: maxBytes) {
        case .failure(let problem):
            return .rejected(problem.description)
        case .success(let items):
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                var placed: [String] = []
                for item in items {
                    let target = uniqueTarget(destination.appendingPathComponent(item.lastPathComponent))
                    do { try fm.moveItem(at: item, to: target) } catch { try fm.copyItem(at: item, to: target) }
                    quarantine(target)
                    placed.append(target.lastPathComponent)
                }
                return .received(placed)
            } catch {
                return .rejected("could not save the files: \(error.localizedDescription)")
            }
        }
    }

    /// `name`, or `name 2`, `name 3`… with the extension kept, so nothing already there is replaced.
    static func uniqueTarget(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else { return url }
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: quarantine

    private static let attribute = "com.apple.quarantine"

    /// Marks a received file, and everything under a received folder, as downloaded, so Gatekeeper
    /// treats a program from a guest as it would one from a browser.
    static func quarantine(_ root: URL) {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));openVM;"
        var targets = [root]
        if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walk { targets.append(url) }
        }
        for url in targets {
            _ = value.withCString { setxattr(url.path, attribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        }
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
