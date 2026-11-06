// What the host accepts from a guest's outbox. The guest is untrusted, so every name and every
// entry is checked before anything is moved to the Mac.
import Foundation
import Testing

@testable import OpenVMCore

struct OutboxRulesTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("outbox-test-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: URL, _ path: String, _ bytes: Int = 4) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
    }

    @Test func goodTreePasses() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt")
        try write(root, "dir/b.txt")
        try write(root, "dir/sub/c.txt")
        let result = OutboxRules.vet(manifest: "a.txt\ndir\n", root: root, maxBytes: 1 << 20)
        guard case .success(let items) = result else { Issue.record("expected success: \(result)"); return }
        #expect(items.map(\.lastPathComponent) == ["a.txt", "dir"])
    }

    @Test func symlinkInOutboxIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("evil").path, withDestinationPath: "/etc/passwd")
        let top = OutboxRules.vet(manifest: "evil\n", root: root, maxBytes: 1 << 20)
        #expect(top == .failure(.notPlain("evil")))
        // A link hidden inside a folder is found too.
        try write(root, "dir/ok.txt")
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dir/link").path, withDestinationPath: "ok.txt")
        let nested = OutboxRules.vet(manifest: "dir\n", root: root, maxBytes: 1 << 20)
        #expect(nested == .failure(.notPlain("dir/link")))
    }

    @Test func traversalNameIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../x", "a/b", "..", ".", ""] {
            let result = OutboxRules.vet(manifest: bad + "\n", root: root, maxBytes: 1 << 20)
            if case .success = result { Issue.record("\(bad.debugDescription) passed") }
        }
    }

    @Test func fifoIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(root.appendingPathComponent("pipe").path, 0o600) == 0)
        let result = OutboxRules.vet(manifest: "pipe\n", root: root, maxBytes: 1 << 20)
        #expect(result == .failure(.notPlain("pipe")))
    }

    @Test func manifestListingMissingFileIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt")
        let result = OutboxRules.vet(manifest: "a.txt\nghost.txt\n", root: root, maxBytes: 1 << 20)
        #expect(result == .failure(.missing("ghost.txt")))
    }

    @Test func overQuotaIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "big.bin", 1000)
        try write(root, "dir/more.bin", 1000)
        #expect(OutboxRules.vet(manifest: "big.bin\ndir\n", root: root, maxBytes: 1500) == .failure(.tooLarge))
        #expect(OutboxRules.vet(manifest: "big.bin\ndir\n", root: root, maxBytes: 2000) != .failure(.tooLarge))
    }

    @Test func emptyDuplicateAndTooManyAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "a.txt")
        #expect(OutboxRules.vet(manifest: "", root: root, maxBytes: 100) == .failure(.nothingToSend))
        #expect(OutboxRules.vet(manifest: "a.txt\na.txt\n", root: root, maxBytes: 100) == .failure(.duplicate("a.txt")))
        let many = (0..<65).map { "f\($0)" }.joined(separator: "\n")
        #expect(OutboxRules.vet(manifest: many, root: root, maxBytes: 100) == .failure(.tooManyItems))
    }

    @Test func unicodeNamesAreComposed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "café.txt")
        let result = OutboxRules.vet(manifest: "café.txt\n", root: root, maxBytes: 100)
        guard case .success = result else { Issue.record("expected success: \(result)"); return }
    }
}
