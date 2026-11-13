// The fields the library's table needs: when a VM was last started, what system it runs, and how much
// space its disk really uses. All optional, so records and rows from before them still read.
import Foundation
import Testing

@testable import OpenVMCore

@Suite struct LibraryFieldsTests {
    private func makeRegistry() throws -> (VmRegistry, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("openvm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return (VmRegistry(path: home.appendingPathComponent("vms.json")), home)
    }

    @Test func aNewVmHasNeverBeenStartedAndKeepsItsSystemName() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let vm = try reg.create(name: "u", bootMode: .linuxISO, systemName: "Ubuntu 26.04")
        #expect(vm.lastStartedAt == nil)
        #expect(try reg.resolve("u").systemName == "Ubuntu 26.04")
        #expect(try reg.create(name: "plain", bootMode: .windows).systemName == nil)
    }

    @Test func startingWritesWhen() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try reg.create(name: "u", bootMode: .linuxISO)
        let before = Date().addingTimeInterval(-2)
        let started = try reg.start("u")
        let stamp = try #require(started.lastStartedAt)
        let when = try #require(VmRegistry.iso8601.date(from: stamp))
        #expect(when >= before)
        // Stopping keeps it: it is when the VM was last used.
        #expect(try reg.stop("u").lastStartedAt == stamp)
    }

    /// A registry written by a newer openVM, with the new fields, reads with this decoder; and one
    /// written before them still reads, with nothing in them.
    @Test func recordsWithAndWithoutTheFieldsBothDecode() throws {
        let (reg, home) = try makeRegistry()
        defer { try? FileManager.default.removeItem(at: home) }
        let json = """
            {"vms":[
              {"uuid":"A","name":"new","state":"stopped","cpus":4,"memoryMB":4096,"bootMode":"linux-iso",
               "lastStartedAt":"2026-11-13T08:00:00Z","systemName":"Fedora Workstation 45","createdAt":"2026-11-01T00:00:00Z"},
              {"uuid":"B","name":"old","state":"stopped","cpus":4,"memoryMB":4096,"bootMode":"windows","createdAt":"2026-01-01T00:00:00Z"}
            ]}
            """
        try Data(json.utf8).write(to: reg.path)
        let vms = try reg.list()
        #expect(vms[0].lastStartedAt == "2026-11-13T08:00:00Z")
        #expect(vms[0].systemName == "Fedora Workstation 45")
        #expect(vms[1].lastStartedAt == nil)
        #expect(vms[1].systemName == nil)
    }

    @Test func aRowCarriesThemAndAnOlderRowDoesNot() {
        let full = VmSummary(
            row: .map([
                ("name", .text("u")), ("uuid", .text("A")), ("state", .text("stopped")),
                ("lastStartedAt", .text("2026-11-13T08:00:00Z")), ("systemName", .text("Ubuntu 26.04")),
                ("diskBytes", .uint(64 << 30)), ("diskUsedBytes", .uint(9 << 30)), ("createdAt", .text("2026-11-01T00:00:00Z")),
            ]))!
        #expect(full.lastStarted == VmRegistry.iso8601.date(from: "2026-11-13T08:00:00Z"))
        #expect(full.created == VmRegistry.iso8601.date(from: "2026-11-01T00:00:00Z"))
        #expect(full.systemName == "Ubuntu 26.04")
        #expect(full.diskUsedBytes == 9 << 30)
        let old = VmSummary(row: .map([("name", .text("u")), ("uuid", .text("A")), ("state", .text("stopped"))]))!
        #expect(old.lastStarted == nil)
        #expect(old.created == nil)
        #expect(old.systemName == nil)
        #expect(old.diskUsedBytes == nil)
    }

    /// The name is shown in the library and comes from a client, so it is short, one line, printable.
    @Test func aSystemNameIsOneShortPrintableLine() {
        #expect(VmRegistry.validSystemName("Ubuntu 26.04 LTS"))
        #expect(VmRegistry.validSystemName("omarchy-4.5.0-aarch64.iso"))
        #expect(!VmRegistry.validSystemName(""))
        #expect(!VmRegistry.validSystemName("   "))
        #expect(!VmRegistry.validSystemName("two\nlines"))
        #expect(!VmRegistry.validSystemName(String(repeating: "x", count: 81)))
        #expect(!VmRegistry.validSystemName("bell\u{7}"))
    }
}
