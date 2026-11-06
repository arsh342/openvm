// The host's small HTTP endpoint: what it serves to a guest, and what it refuses.
import Darwin
import Foundation
import OpenVMCore
import Testing

@testable import OpenVMHost

nonisolated struct ArtifactReceiverTests {
    private func makeOverlay(_ bytes: String = "overlay-bytes") throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("openvm.apkovl.tar.gz")
        try Data(bytes.utf8).write(to: file)
        return (file, { try? FileManager.default.removeItem(at: dir) })
    }

    private func startReceiver(
        overlay: URL?, allowsPeer: @escaping @Sendable ([UInt8]) -> Bool = { _ in true }
    ) throws -> ArtifactReceiver {
        let registryHome = FileManager.default.temporaryDirectory.appendingPathComponent("rh-\(UUID().uuidString).json")
        let receiver = ArtifactReceiver(
            registry: VmRegistry(path: registryHome), port: 0, allowsPeer: allowsPeer, overlay: { overlay })
        try receiver.start()
        return receiver
    }

    /// One raw HTTP request, so a path is sent exactly as written. Returns the status line and body.
    private func request(_ path: String, port: UInt16, method: String = "GET") -> (status: String, body: String) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return ("connect failed", "") }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let text = "\(method) \(path) HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        _ = text.withCString { send(fd, $0, strlen($0), 0) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        let whole = String(decoding: data, as: UTF8.self)
        let parts = whole.components(separatedBy: "\r\n\r\n")
        return (parts.first?.components(separatedBy: "\r\n").first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    @Test func servesTheOverlayToTheGuestNetwork() throws {
        let (file, cleanup) = try makeOverlay()
        defer { cleanup() }
        let receiver = try startReceiver(overlay: file)
        let reply = request("/openvm.apkovl.tar.gz", port: receiver.boundPort)
        #expect(reply.status == "HTTP/1.1 200 OK")
        #expect(reply.body == "overlay-bytes")
    }

    @Test func aPeerOutsideTheGuestNetworkIsRefused() throws {
        let (file, cleanup) = try makeOverlay()
        defer { cleanup() }
        let receiver = try startReceiver(overlay: file, allowsPeer: { _ in false })
        #expect(request("/openvm.apkovl.tar.gz", port: receiver.boundPort).status == "HTTP/1.1 403 Forbidden")
    }

    @Test func noOverlayIsNotFoundNotACrash() throws {
        let receiver = try startReceiver(overlay: nil)
        #expect(request("/openvm.apkovl.tar.gz", port: receiver.boundPort).status == "HTTP/1.1 404 Not Found")
    }

    /// Only the exact names are served, so no path can reach any other file.
    @Test func onlyExactNamesAreServed() throws {
        let (file, cleanup) = try makeOverlay("secret-free-overlay")
        defer { cleanup() }
        let receiver = try startReceiver(overlay: file)
        for path in [
            "/", "/../etc/passwd", "/openvm.apkovl.tar.gz/../../etc/passwd", "//openvm.apkovl.tar.gz",
            "/openvm.apkovl.tar.gz?x=1", "/openvm.apkovl.tar.gz/", "/OPENVM.APKOVL.TAR.GZ", "/etc/passwd",
            "/openvm.apkovl.tar.gz%00",
        ] {
            let reply = request(path, port: receiver.boundPort)
            #expect(reply.status != "HTTP/1.1 200 OK", "\(path) was served")
            #expect(!reply.body.contains("root:"), "\(path) leaked a file")
        }
    }

    @Test func onlyGetServesFiles() throws {
        let (file, cleanup) = try makeOverlay()
        defer { cleanup() }
        let receiver = try startReceiver(overlay: file)
        #expect(request("/openvm.apkovl.tar.gz", port: receiver.boundPort, method: "PUT").status != "HTTP/1.1 200 OK")
    }

    @Test func onlyTheGuestSubnetIsAGuestPeer() {
        #expect(ArtifactReceiver.isGuestPeer([192, 168, 64, 2]))
        #expect(!ArtifactReceiver.isGuestPeer([192, 168, 65, 2]))
        #expect(!ArtifactReceiver.isGuestPeer([10, 0, 0, 1]))
        #expect(!ArtifactReceiver.isGuestPeer([127, 0, 0, 1]))
        #expect(!ArtifactReceiver.isGuestPeer([]))
    }
}
