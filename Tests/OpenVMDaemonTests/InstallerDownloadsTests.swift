// The host's installer downloads, against a small HTTP server on this Mac: a good download, a damaged
// one, a missing one, a cut-off one that is picked up again, cancelling and resuming, a full disk, a
// second start, and an index that tries to send the host elsewhere.
import CryptoKit
import Darwin
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

/// A few routes served over plain HTTP on 127.0.0.1, with Range support, for one test.
private nonisolated final class LocalServer: @unchecked Sendable {
    struct Route {
        var status = 200
        var body = Data()
        /// Send only this many bytes of the body, then close: a download cut off part-way.
        var cutAfter: Int?
        /// Pause this long between chunks, so a test can cancel in the middle.
        var chunkDelay: TimeInterval = 0
        var location: String?
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var seen: [(path: String, range: String?)] = []
    private let listener: Int32
    let port: UInt16

    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(fd, 16)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                Thread.detachNewThread { self?.serve(client) ?? { close(client) }() }
            }
        }
    }

    deinit { close(listener) }

    func set(_ path: String, _ route: Route) { lock.withLock { routes[path] = route } }
    var requests: [(path: String, range: String?)] { lock.withLock { seen } }
    func count(_ path: String) -> Int { requests.filter { $0.path == path }.count }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var head = Data()
        var byte = [UInt8](repeating: 0, count: 1024)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(client, &byte, byte.count, 0)
            if n <= 0 { return }
            head.append(contentsOf: byte.prefix(n))
        }
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let range = lines.first { $0.lowercased().hasPrefix("range:") }?.split(separator: ":", maxSplits: 1)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let route = lock.withLock { () -> Route? in
            seen.append((path, range))
            return routes[path]
        }
        func send(_ text: String) { _ = text.withCString { Darwin.send(client, $0, strlen($0), 0) } }
        guard let route else {
            return send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        if let location = route.location {
            return send(
                "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
        }
        if route.status != 200 {
            return send("HTTP/1.1 \(route.status) Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        var start = 0
        if let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).dropLast()) {
            start = from
        }
        if start > route.body.count || (start == route.body.count && start > 0) {
            return send(
                "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        let body = route.body.subdata(in: start..<route.body.count)
        if start > 0 {
            send(
                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(route.body.count - 1)/\(route.body.count)\r\n"
            )
        } else {
            send("HTTP/1.1 200 OK\r\n")
        }
        send("Content-Length: \(body.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n")
        let limit = min(body.count, route.cutAfter.map { max(0, $0 - start) } ?? body.count)
        var sent = 0
        while sent < limit {
            let chunk = min(16 * 1024, limit - sent)
            let wrote = body.withUnsafeBytes { Darwin.send(client, $0.baseAddress! + sent, chunk, 0) }
            if wrote <= 0 { return }
            sent += wrote
            if route.chunkDelay > 0 { Thread.sleep(forTimeInterval: route.chunkDelay) }
        }
    }
}

nonisolated struct InstallerDownloadsTests {
    private static let fileName = "ubuntu-26.04.1-desktop-arm64.iso"

    private struct Fixture {
        let server = LocalServer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "openvm-isos-\(UUID().uuidString)")
        let body: Data
        let entry = InstallerCatalog.Entry(
            id: "test-linux", name: "Test Linux", purpose: "p", kind: .linux,
            source: .ubuntu(release: "26.04"),
            downloadGB: 0.001, neededGB: 1, time: "t", limits: ["l"], evidence: nil,
            page: URL(string: "https://example.org")!,
            symbol: "circle")

        init(bytes: Int = 300_000) {
            var data = Data(count: bytes)
            for index in 0..<bytes { data[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 8) }
            body = data
        }

        var hash: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }
        var isoPath: String { "/" + InstallerDownloadsTests.fileName }
        var final: URL { directory.appendingPathComponent("test-linux-" + InstallerDownloadsTests.fileName) }
        var part: URL { final.appendingPathExtension("part") }

        /// Publishes the index and the file as a vendor would.
        func publish(hash: String? = nil, file: LocalServer.Route? = nil) {
            server.set(
                "/SHA256SUMS",
                .init(body: Data("\(hash ?? self.hash) *\(InstallerDownloadsTests.fileName)\n".utf8)))
            server.set(isoPath, file ?? .init(body: body))
        }

        func downloads(
            free: UInt64 = 100 << 30, requireHTTPS: Bool = false, alsoFrom hosts: [String] = [],
            check: @escaping @Sendable (URL) -> String? = { _ in nil }
        ) -> InstallerDownloads {
            let index = server.url("/SHA256SUMS")
            return InstallerDownloads(
                environment: .init(
                    directory: directory, entries: [entry], indexURL: { _ in index },
                    indexHosts: { _ in hosts },
                    requireHTTPS: requireHTTPS,
                    freeBytes: { free }, check: check))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Starts a download and waits for it to leave `running`. The waits give their thread back: URLSession
    /// needs the same threads the tests run on, and tests that sleep on them stall every download.
    private func run(_ downloads: InstallerDownloads, seconds: Double = 10) async throws
        -> InstallerDownloads.Snapshot
    {
        let id = try downloads.start(entry: "test-linux").get()
        let found = await finish(downloads, id, seconds: seconds)
        return try #require(found)
    }

    private func finish(_ downloads: InstallerDownloads, _ id: String, seconds: Double = 10) async
        -> InstallerDownloads.Snapshot?
    {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let snapshot = downloads.status(id), snapshot.state != .running { return snapshot }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return downloads.status(id)
    }

    /// Waits until a download has received something.
    private func started(_ downloads: InstallerDownloads, _ id: String) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (downloads.status(id)?.bytesDone ?? 0) == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aGoodDownloadIsVerifiedAndPutInPlace() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        let done = try await run(fixture.downloads())
        #expect(done.state == .done)
        #expect(done.path == fixture.final.path)
        #expect(done.bytesDone == UInt64(fixture.body.count))
        #expect(done.bytesTotal == UInt64(fixture.body.count))
        #expect(try Data(contentsOf: fixture.final) == fixture.body)
        #expect(!FileManager.default.fileExists(atPath: fixture.part.path))
    }

    /// A file that does not match the vendor's hash is removed and never used.
    @Test func aDamagedDownloadIsRemovedNotUsed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish(hash: String(repeating: "0", count: 64))
        let failed = try await run(fixture.downloads())
        #expect(failed.state == .failed)
        #expect(failed.code == "download-damaged")
        #expect(failed.error?.contains(fixture.hash) == true)  // both hashes are in the details
        #expect(failed.path == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.final.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.part.path))
    }

    @Test func aFileTheExistingCheckRefusesIsRemovedToo() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        let failed = try await run(fixture.downloads(check: { _ in "This ISO is for Intel and AMD PCs." }))
        #expect(failed.code == "download-damaged")
        #expect(!FileManager.default.fileExists(atPath: fixture.final.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.part.path))
    }

    @Test func aMissingFileOrAnEmptyIndexIsNotFound() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.server.set("/SHA256SUMS", .init(body: Data("\(fixture.hash) *\(Self.fileName)\n".utf8)))  // no file
        #expect(try await run(fixture.downloads()).code == "installer-not-found")
        fixture.server.set("/SHA256SUMS", .init(body: Data("nothing for this Mac\n".utf8)))
        #expect(try await run(fixture.downloads()).code == "installer-not-found")
        fixture.server.set("/SHA256SUMS", .init(status: 404))
        #expect(try await run(fixture.downloads()).code == "installer-not-found")
    }

    /// A download cut off part-way keeps what it has, and the next start asks only for the rest.
    @Test func aCutOffDownloadIsPickedUpWhereItStopped() async throws {
        // Large and unhurried enough that what arrived before the cut has been handed over, as with a real file.
        let fixture = Fixture(bytes: 2_000_000)
        defer { fixture.cleanUp() }
        fixture.publish(file: .init(body: fixture.body, cutAfter: 1_500_000, chunkDelay: 0.002))
        let downloads = fixture.downloads()
        let cut = try await run(downloads)
        #expect(cut.state == .failed)
        #expect(cut.code == "download-failed")
        let have = try #require(
            (try FileManager.default.attributesOfItem(atPath: fixture.part.path))[.size] as? Int)
        #expect(have > 0 && have < fixture.body.count)

        fixture.publish()  // the server is well again
        let done = try await run(downloads)
        #expect(done.state == .done)
        #expect(try Data(contentsOf: fixture.final) == fixture.body)
        #expect(fixture.server.requests.last { $0.path == fixture.isoPath }?.range == "bytes=\(have)-")
    }

    @Test func cancellingKeepsThePartAndStartingAgainFinishesIt() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish(file: .init(body: fixture.body, chunkDelay: 0.05))
        let downloads = fixture.downloads()
        let id = try downloads.start(entry: "test-linux").get()
        await started(downloads, id)
        #expect(downloads.running().map(\.id) == [id])
        #expect(downloads.cancel(id))
        #expect(await finish(downloads, id)?.state == .cancelled)
        #expect(FileManager.default.fileExists(atPath: fixture.part.path))
        #expect(downloads.cached().map(\.complete) == [false])

        fixture.publish()
        #expect(try await run(downloads).state == .done)
        #expect(try Data(contentsOf: fixture.final) == fixture.body)
        #expect(downloads.cached().map(\.complete) == [true])
    }

    /// With too little room for the download and a VM's disk, nothing is fetched at all.
    @Test func aFullDiskIsRefusedBeforeAnythingIsDownloaded() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        let refused = try await run(fixture.downloads(free: 100_000))
        #expect(refused.state == .failed)
        #expect(refused.code == "no-space")
        #expect(fixture.server.count(fixture.isoPath) == 0)
    }

    @Test func aSecondStartJoinsTheRunningOneAndAVerifiedFileIsNotFetchedAgain() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish(file: .init(body: fixture.body, chunkDelay: 0.02))
        let downloads = fixture.downloads()
        let first = try downloads.start(entry: "test-linux").get()
        #expect(try downloads.start(entry: "test-linux").get() == first)
        #expect(await finish(downloads, first)?.state == .done)
        #expect(fixture.server.count(fixture.isoPath) == 1)
        // Already there and verified: the next start answers at once with the same file.
        let again = try await run(downloads)
        #expect(again.state == .done)
        #expect(again.path == fixture.final.path)
        #expect(fixture.server.count(fixture.isoPath) == 1)
    }

    /// The index must come from the vendor's own host: one that redirects elsewhere is refused.
    @Test func anIndexThatRedirectsToAnotherHostIsRefused() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        fixture.server.set("/elsewhere", .init(body: Data("\(fixture.hash) *\(Self.fileName)\n".utf8)))
        fixture.server.set(
            "/SHA256SUMS", .init(location: "http://localhost:\(fixture.server.port)/elsewhere"))
        let refused = try await run(fixture.downloads())
        #expect(refused.state == .failed)
        #expect(refused.error?.contains("another host") == true)
        #expect(fixture.server.count(fixture.isoPath) == 0)
    }

    /// A vendor may serve its index from a second host of its own, as Kali does: a redirect there is followed.
    @Test func anIndexMayRedirectToAnotherOfTheVendorsOwnHosts() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        fixture.server.set("/elsewhere", .init(body: Data("\(fixture.hash) *\(Self.fileName)\n".utf8)))
        fixture.server.set(
            "/SHA256SUMS", .init(location: "http://localhost:\(fixture.server.port)/elsewhere"))
        let done = try await run(fixture.downloads(alsoFrom: ["localhost"]))
        #expect(done.state == .done)
        #expect(try Data(contentsOf: fixture.final) == fixture.body)
    }

    /// The real host insists on HTTPS: a plain address is refused without a request being made.
    @Test func plainHttpIsRefusedUnlessATestAllowsIt() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        let refused = try await run(fixture.downloads(requireHTTPS: true))
        #expect(refused.state == .failed)
        #expect(refused.error?.contains("HTTPS") == true)
        #expect(fixture.server.requests.isEmpty)
    }

    /// A client names a catalog entry. Anything else, an address above all, starts nothing.
    @Test func onlyACatalogEntryStartsADownload() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let downloads = fixture.downloads()
        for bad in ["", "windows-11", "https://example.org/a.iso", "../test-linux", "/etc/passwd"] {
            if case .success = downloads.start(entry: bad) { Issue.record("\(bad) started a download") }
        }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func removingAnInstallerFreesItAndStopsItsDownload() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.publish()
        let downloads = fixture.downloads()
        #expect(try await run(downloads).state == .done)
        #expect(
            downloads.cached() == [
                .init(
                    entry: "test-linux", file: Self.fileName, path: fixture.final.path,
                    bytes: UInt64(fixture.body.count), complete: true)
            ])
        #expect(downloads.remove(entry: "test-linux") >= UInt64(fixture.body.count))
        #expect(downloads.cached().isEmpty)
        #expect(downloads.remove(entry: "not-in-the-catalog") == 0)

        fixture.publish(file: .init(body: fixture.body, chunkDelay: 0.05))
        let id = try downloads.start(entry: "test-linux").get()
        await started(downloads, id)
        _ = downloads.remove(entry: "test-linux")
        #expect(downloads.status(id)?.state == .cancelled)
        #expect(downloads.cached().isEmpty)
    }
}
