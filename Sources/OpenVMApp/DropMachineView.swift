// DropMachineView — the guest's screen, which also accepts files dragged onto it.
//
// It is the machine view itself, subclassed, so keyboard and mouse still go to the guest exactly as
// before; only drags are intercepted. Files are handed to the host to copy in. Items that are only
// promised by their source (Photos, Mail) are first written to a temporary folder here.
import AppKit
import OpenVMCore
import Virtualization

@MainActor
final class DropMachineView: VZVirtualMachineView {
    /// Whether a drop is welcome right now (the guest is running and no other drop is).
    var acceptsDrops: () -> Bool = { false }
    /// Called with the files to take to the guest, and a folder to remove afterwards (or nil).
    var onFiles: ([URL], URL?) -> Void = { _, _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) })
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrops() ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptsDrops() ? .copy : []
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptsDrops() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        let classes: [AnyClass] = [NSFilePromiseReceiver.self, NSURL.self]
        guard let items = board.readObjects(forClasses: classes, options: [.urlReadingFileURLsOnly: true]),
            !items.isEmpty
        else { return false }

        var files = items.compactMap { ($0 as? URL) }
        let promises = items.compactMap { $0 as? NSFilePromiseReceiver }
        if promises.isEmpty {
            onFiles(files, nil)
            return true
        }
        // Promised files do not exist yet. They are written to a folder of ours first.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openvm-drop-\(UUID().uuidString.lowercased())")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            return false
        }
        let queue = OperationQueue()
        let lock = NSLock()
        var received: [URL] = []
        let group = DispatchGroup()
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                if error == nil { lock.withLock { received.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                files += lock.withLock { received }
                if files.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                } else {
                    self?.onFiles(files, folder)
                }
            }
        }
        return true
    }
}
