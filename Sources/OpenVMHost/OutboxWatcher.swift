// OutboxWatcher — notices when a guest has put files in its outbox, and takes them to the Mac.
//
// One kernel event source per running guest, on that guest's outbox folder. Nothing is polled: the
// guest tool finishes a set by renaming a folder into place, which is a single event here. What
// arrives is vetted and moved by OutboxIntake; this only decides when to look and tells the app.
import Darwin
import Foundation

/// What the app is told after a set has been handled.
public struct OutboxReceipt: Sendable, Equatable {
    public let uuid: String
    public let vmName: String
    /// The names now in `folder`; empty when the set was rejected.
    public let items: [String]
    public let folder: URL
    /// Why the set was refused, if it was.
    public let rejection: String?
}

/// The guest's outbox on the host. Present from boot, like `drops`.
nonisolated func outboxRoot(_ uuid: String, create: Bool) throws -> URL {
    let root = home.appendingPathComponent("outbox").appendingPathComponent(uuid)
    if create {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The guest tool runs as the desktop user, whose id differs from this Mac user's; the share
        // carries the host mode through, so the folder must let any guest user add to it.
        chmod(root.path, 0o777)
    }
    return root
}

/// Where received files go: `~/Downloads/openVM/<vm name>`.
nonisolated func receivedFolder(forVM name: String) -> URL {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    return downloads.appendingPathComponent("openVM").appendingPathComponent(name)
}

nonisolated final class OutboxWatcher: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let queue = DispatchQueue(label: "openvm.outbox", qos: .utility)

    /// The space kept free on the Mac when taking files: a guest cannot fill the disk with a send.
    private static let reserve: UInt64 = 2 << 30

    init?(uuid: String, name: String, outbox: URL, destination: URL, report: @escaping @Sendable (OutboxReceipt) -> Void) {
        let fd = open(outbox.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .extend], queue: queue)
        let handle: @Sendable () -> Void = {
            let budget = Self.budget(for: destination)
            for result in OutboxIntake.collect(outbox: outbox, into: destination, maxBytes: budget) {
                switch result {
                case .received(let items):
                    note("openvm: \(name): received \(items.count) item(s) from the guest")
                    report(OutboxReceipt(uuid: uuid, vmName: name, items: items, folder: destination, rejection: nil))
                case .rejected(let why):
                    note("openvm: \(name): refused what the guest sent: \(why)")
                    report(OutboxReceipt(uuid: uuid, vmName: name, items: [], folder: destination, rejection: why))
                }
            }
        }
        source.setEventHandler(handler: handle)
        source.setCancelHandler { close(fd) }
        source.resume()
        // Something may have been left by a send that raced the watcher starting.
        queue.async(execute: handle)
    }

    func stop() { source.cancel() }

    /// Free space on the destination's volume, less the reserve.
    static func budget(for destination: URL) -> UInt64 {
        var probe = destination
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let free = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let bytes = UInt64(max(0, free))
        return bytes > reserve ? bytes - reserve : 0
    }
}

/// The running watchers, one per guest.
nonisolated final class OutboxWatchers: @unchecked Sendable {
    private let lock = NSLock()
    private var watchers: [String: OutboxWatcher] = [:]
    private var handler: (@Sendable (OutboxReceipt) -> Void)?

    func setHandler(_ handler: (@Sendable (OutboxReceipt) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    func start(uuid: String, name: String) {
        guard let outbox = try? outboxRoot(uuid, create: true) else { return }
        let watcher = OutboxWatcher(
            uuid: uuid, name: name, outbox: outbox, destination: receivedFolder(forVM: name)
        ) { [weak self] receipt in
            let handler = self?.lock.withLock { self?.handler }
            handler?(receipt)
        }
        lock.withLock {
            watchers[uuid]?.stop()
            watchers[uuid] = watcher
        }
    }

    func stop(uuid: String) {
        let watcher = lock.withLock { watchers.removeValue(forKey: uuid) }
        watcher?.stop()
    }
}

nonisolated let outboxWatchers = OutboxWatchers()
