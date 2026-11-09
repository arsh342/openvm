// Taking a guest's sent files into the Mac's Downloads folder.
import Foundation
import Testing

@testable import OpenVMHost

struct OutboxIntakeTests {
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("intake-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One complete set, the way the guest tool leaves it: a folder of items and a manifest.
    private func send(_ outbox: URL, id: String, files: [String: String], manifest: String? = nil) throws {
        let dir = outbox.appendingPathComponent(id)
        for (name, text) in files {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let top = Set(files.keys.map { String($0.split(separator: "/").first!) }).sorted()
        try Data((manifest ?? top.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(".ready"))
    }

    @Test func aCompleteSetMovesToTheDestinationAndTheOutboxIsEmptied() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try send(outbox, id: "one", files: ["a.txt": "hello", "d/b.txt": "world"])
        let results = OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20)
        #expect(results == [.received(["a.txt", "d"])])
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")
        #expect(try String(contentsOf: dest.appendingPathComponent("d/b.txt"), encoding: .utf8) == "world")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.path).isEmpty)
    }

    @Test func aSetWithoutItsReadyMarkIsLeftAlone() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        let dir = outbox.appendingPathComponent("half")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        #expect(OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20).isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func hiddenEntriesAreNotTakenAsSets() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try send(outbox, id: ".incoming-x", files: ["a.txt": "hello"])
        #expect(OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20).isEmpty)
    }

    @Test func aRejectedSetIsDeletedAndReported() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try send(outbox, id: "bad", files: ["a.txt": "hello"], manifest: "a.txt\n../escape\n")
        let results = OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20)
        guard case .rejected(let why)? = results.first else { Issue.record("expected a rejection: \(results)"); return }
        #expect(why.contains("escape"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func aNameAlreadyThereIsNotOverwritten() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try Data("mine".utf8).write(to: dest.appendingPathComponent("a.txt"))
        try send(outbox, id: "one", files: ["a.txt": "theirs"])
        let results = OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20)
        #expect(results == [.received(["a 2.txt"])])
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "mine")
        #expect(try String(contentsOf: dest.appendingPathComponent("a 2.txt"), encoding: .utf8) == "theirs")
    }

    @Test func receivedFilesCarryTheQuarantineMark() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try send(outbox, id: "one", files: ["a.txt": "hello", "d/b.txt": "world"])
        _ = OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20)
        for path in ["a.txt", "d/b.txt"] {
            #expect(OutboxIntake.hasQuarantine(dest.appendingPathComponent(path)), "\(path)")
        }
    }

    @Test func aSymlinkIsRejectedEvenInsideAFolder() throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        try send(outbox, id: "one", files: ["d/ok.txt": "x"])
        try FileManager.default.createSymbolicLink(
            atPath: outbox.appendingPathComponent("one/d/link").path, withDestinationPath: "/etc/hosts")
        let results = OutboxIntake.collect(outbox: outbox, into: dest, maxBytes: 1 << 20)
        guard case .rejected? = results.first else { Issue.record("expected a rejection: \(results)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
}

struct OutboxWatcherTests {
    private nonisolated final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [OutboxReceipt] = []
        func add(_ r: OutboxReceipt) { lock.withLock { items.append(r) } }
        var all: [OutboxReceipt] { lock.withLock { items } }
    }

    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The guest tool's way of finishing a send: build hidden, mark ready, rename into place.
    @Test func aSetRenamedIntoPlaceIsTakenWithoutPolling() async throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        let box = Box()
        let watcher = OutboxWatcher(uuid: "u", name: "vm", outbox: outbox, destination: dest) { box.add($0) }
        #expect(watcher != nil)
        let hidden = outbox.appendingPathComponent(".incoming-1")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: hidden.appendingPathComponent("a.txt"))
        try Data("a.txt\n".utf8).write(to: hidden.appendingPathComponent(".ready"))
        try FileManager.default.moveItem(at: hidden, to: outbox.appendingPathComponent("1"))
        for _ in 0..<100 where box.all.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.all.first?.items == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.txt").path))
        watcher?.stop()
    }

    @Test func aStoppedWatcherSeesNothing() async throws {
        let outbox = try temp(), dest = try temp()
        defer { try? FileManager.default.removeItem(at: outbox); try? FileManager.default.removeItem(at: dest) }
        let box = Box()
        let watcher = OutboxWatcher(uuid: "u", name: "vm", outbox: outbox, destination: dest) { box.add($0) }
        watcher?.stop()
        try await Task.sleep(for: .milliseconds(50))
        let set = outbox.appendingPathComponent("1")
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: set.appendingPathComponent("a.txt"))
        try Data("a.txt\n".utf8).write(to: set.appendingPathComponent(".ready"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(box.all.isEmpty)
    }
}
