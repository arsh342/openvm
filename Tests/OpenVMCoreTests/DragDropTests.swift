// Tests for drop naming rules.
import Testing

@testable import OpenVMCore

@Suite struct DragDropTests {
    @Test func ordinaryNamesPass() {
        for name in ["a.txt", "Résumé final (2).pdf", "日本語", ".hidden", "-dash", "a b"] {
            #expect(DragDrop.validItemName(name))
        }
    }

    @Test func escapingNamesAreRefused() {
        for name in ["", ".", "..", "a/b", "../x", "line\nbreak", "tab\there", "del\u{7f}"] {
            #expect(!DragDrop.validItemName(name))
        }
        #expect(!DragDrop.validItemName(String(repeating: "x", count: 256)))
    }

    @Test func itemNamesComeFromTheLastComponent() throws {
        #expect(try DragDrop.itemNames(for: ["/Users/a/one.txt", "/tmp/dir/"]).get() == ["one.txt", "dir"])
    }

    /// The form a Mac hands over, and the form a guest should get.
    @Test func namesArriveComposed() throws {
        let decomposed = "/tmp/Re\u{301}sume\u{301}.pdf"
        let name = try #require(try? DragDrop.itemNames(for: [decomposed]).get().first)
        #expect(Array(name.unicodeScalars) == Array("R\u{e9}sum\u{e9}.pdf".unicodeScalars))
    }

    @Test func twoItemsCannotShareAName() {
        #expect(DragDrop.itemNames(for: ["/a/x", "/b/x"]) == .failure(.duplicateName("x")))
        #expect(DragDrop.itemNames(for: []) == .failure(.nothingToDrop))
        let many = (0...DragDrop.maxItems).map { "/a/\($0)" }
        #expect(DragDrop.itemNames(for: many) == .failure(.tooManyItems))
    }

    @Test func statusParses() {
        let reply = CBOR.map([
            ("accepted", .bool(true)), ("done", .bool(true)),
            ("placed", .array([.text("a"), .text("b (2)")])), ("bytes", .uint(12)),
        ])
        #expect(
            DragDrop.status(reply) == DropStatus(done: true, placed: ["a", "b (2)"], bytes: 12, error: nil))
        #expect(DragDrop.status(.map([("accepted", .bool(true))])) == nil)
    }
}
