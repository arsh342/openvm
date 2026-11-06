// Where the app finds the files it needs to build a guest, and what it will serve from them.
import Foundation
import Testing

@testable import OpenVMHost

struct GuestPayloadTests {
    private func makePayload(overlay: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("linux"), withIntermediateDirectories: true)
        if overlay {
            try Data("overlay".utf8).write(to: root.appendingPathComponent("linux/openvm.apkovl.tar.gz"))
        }
        return root
    }

    @Test func theEnvironmentOverridesEveryOtherPlace() throws {
        let root = try makePayload()
        defer { try? FileManager.default.removeItem(at: root) }
        // Compared as paths: a URL for an existing directory gains a trailing slash.
        #expect(GuestPayload.root(environment: ["OPENVM_PAYLOAD": root.path], bundleResources: nil)?.path == root.path)
    }

    @Test func aBundleCarriesItsPayloadInResources() throws {
        let resources = FileManager.default.temporaryDirectory.appendingPathComponent("res-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resources) }
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("guest/linux"), withIntermediateDirectories: true)
        #expect(
            GuestPayload.root(environment: [:], bundleResources: resources)?.path
                == resources.appendingPathComponent("guest").path)
    }

    @Test func aPathThatIsNotADirectoryIsNotAPayload() {
        #expect(GuestPayload.root(environment: ["OPENVM_PAYLOAD": "/no/such/dir"], bundleResources: nil) == nil)
    }

    @Test func theOverlayIsOnlyOfferedWhenItIsThere() throws {
        let with = try makePayload()
        let without = try makePayload(overlay: false)
        defer {
            try? FileManager.default.removeItem(at: with)
            try? FileManager.default.removeItem(at: without)
        }
        #expect(GuestPayload.overlay(in: with) == with.appendingPathComponent("linux/openvm.apkovl.tar.gz"))
        #expect(GuestPayload.overlay(in: without) == nil)
        #expect(GuestPayload.overlay(in: nil) == nil)
    }
}
