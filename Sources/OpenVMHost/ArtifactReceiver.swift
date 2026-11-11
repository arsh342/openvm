// A small HTTP endpoint on the host: the helper VM fetches its modules and its overlay from it.
import Darwin
import Foundation
import OpenVMCore

/// Serves two fixed files to the helper VM over its NAT network: the pinned modloop, which must match
/// the pinned kernel exactly (Alpine's mirror replaces it with every kernel update), and the overlay
/// that carries the job script. Both are public bytes, and nothing a guest sends names a file.
nonisolated final class ArtifactReceiver: @unchecked Sendable {
    private let port: UInt16
    private let allowsPeer: @Sendable ([UInt8]) -> Bool
    private let overlay: @Sendable () -> URL?
    private let lock = NSLock()
    /// The port actually listening: differs from `port` only when that is 0 (a test lets the
    /// system choose).
    private(set) var boundPort: UInt16 = 0
    private var listener: Int32 = -1
    /// The vmnet shared-network subnet a guest fetches from.
    static let guestSubnetPrefix: [UInt8] = [192, 168, 64]

    init(
        port: UInt16 = 8124,
        allowsPeer: @escaping @Sendable ([UInt8]) -> Bool = ArtifactReceiver.isGuestPeer,
        overlay: @escaping @Sendable () -> URL? = { GuestPayload.overlay }
    ) {
        self.port = port
        self.allowsPeer = allowsPeer
        self.overlay = overlay
    }

    /// Whether an address (as four bytes) belongs to the guest network: only a guest may talk to
    /// this endpoint.
    static func isGuestPeer(_ address: [UInt8]) -> Bool {
        address.count == 4 && Array(address.prefix(3)) == guestSubnetPrefix
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener < 0 else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.ioError("socket") }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let error = Self.ioError("bind/listen on port \(port)")
            Darwin.close(fd)
            throw error
        }
        var named = sockaddr_in()
        var namedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &namedLength) }
        }
        boundPort = UInt16(bigEndian: named.sin_port)
        listener = fd
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var peer = sockaddr_in()
            var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peer) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &peerLen) }
            }
            guard client >= 0 else { continue }
            let addr = withUnsafeBytes(of: peer.sin_addr.s_addr) { Array($0) }
            if allowsPeer(addr) {
                handle(client)
            } else {
                respond(client, status: "403 Forbidden")
            }
            Darwin.close(client)
        }
    }

    static let modloopName = "modloop-virt"
    static let overlayName = GuestPayload.overlayName

    /// Streams one file the host chose (never one the guest named) as a 200, or answers 404.
    private func serveFile(_ fd: Int32, _ chosen: URL?, label: String) {
        guard let file = chosen,
            let input = try? FileHandle(forReadingFrom: file),
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
        else {
            respond(fd, status: "404 Not Found")
            return
        }
        defer { try? input.close() }
        let head =
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
            + "Content-Length: \(size)\r\nConnection: close\r\n\r\n"
        guard (try? UnixSocket.writeAll(fd: fd, Data(head.utf8))) != nil else { return }
        while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
            guard (try? UnixSocket.writeAll(fd: fd, chunk)) != nil else { return }
        }
        note("openvmd: served \(label) (\(size) bytes)")
    }

    private func handle(_ fd: Int32) {
        var header = Data()
        let terminator = Data([13, 10, 13, 10])
        while header.count < 16_384 && !header.suffix(4).elementsEqual(terminator) {
            var byte: UInt8 = 0
            guard Darwin.read(fd, &byte, 1) == 1 else { return }
            header.append(byte)
        }
        guard let text = String(data: header, encoding: .utf8),
            let firstLine = text.components(separatedBy: "\r\n").first
        else {
            respond(fd, status: "400 Bad Request")
            return
        }
        let fields = firstLine.split(separator: " ")
        // Two fixed paths, each to bytes that are public (Alpine's modules, and openVM's own
        // overlay). The host picks the file; nothing the guest sends names one.
        if fields.count == 3, fields[0] == "GET" {
            if fields[1] == "/" + Self.modloopName {
                serveFile(fd, GuestBoot.pinnedModloop(), label: "the pinned modloop")
                return
            }
            if fields[1] == "/" + Self.overlayName {
                serveFile(fd, overlay(), label: "the overlay")
                return
            }
        }
        respond(fd, status: "404 Not Found")
    }

    private func respond(_ fd: Int32, status: String) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = body.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private static func ioError(_ operation: String) -> GuestBootError {
        .failure("artifact receiver \(operation): \(String(cString: strerror(errno)))")
    }
}
