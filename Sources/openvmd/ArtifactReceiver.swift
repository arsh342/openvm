// A small HTTP endpoint on the host: guests upload their installed kernel, and fetch the pinned modules.
import Darwin
import Foundation
import OpenVMCore
import Security

/// Receives the matching installed-kernel and mkinitfs artifacts from Alpine
/// over the VM's NAT network during first-boot disk installation, and serves the
/// pinned modloop to netboot guests. The modloop must match the pinned kernel
/// exactly, and Alpine's mirror replaces it with every kernel update.
nonisolated final class ArtifactReceiver: @unchecked Sendable {
    private let registry: VmRegistry
    private let port: UInt16
    private let lock = NSLock()
    private var listener: Int32 = -1
    /// Per-boot upload tokens, keyed by lowercase VM uuid. The receiver must
    /// listen on every interface (the vmnet gateway only exists once the guest
    /// is up), so the token is what makes it safe: the daemon hands it to the
    /// guest on the kernel command line and nothing else knows it. Without it,
    /// a LAN peer who knew a VM's uuid could replace the kernel it boots next.
    private var tokens: [String: String] = [:]
    /// The vmnet shared-network subnet the guest uploads from.
    static let guestSubnetPrefix: [UInt8] = [192, 168, 64]

    init(registry: VmRegistry, port: UInt16 = 8124) {
        self.registry = registry
        self.port = port
    }

    /// Issue (or replace) the upload token for one VM's next install boot.
    func issueToken(for uuid: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        defer { lock.unlock() }
        tokens[uuid.lowercased()] = token
        return token
    }

    private func token(for uuid: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[uuid.lowercased()]
    }

    /// Constant-time comparison, so a wrong token leaks nothing through timing.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
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
            // Defence in depth behind the token: only the guest network may upload.
            let addr = withUnsafeBytes(of: peer.sin_addr.s_addr) { Array($0) }
            if Array(addr.prefix(3)) == Self.guestSubnetPrefix {
                handle(client)
            } else {
                respond(client, status: "403 Forbidden")
            }
            Darwin.close(client)
        }
    }

    static let modloopName = "modloop-virt"

    private func serveModloop(_ fd: Int32) {
        guard let file = GuestBoot.pinnedModloop(),
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
        note("openvmd: served the pinned modloop (\(size) bytes)")
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
        // The one thing served: a fixed path to public Alpine bytes, so no token.
        if fields.count == 3, fields[0] == "GET", fields[1] == "/" + Self.modloopName {
            serveModloop(fd)
            return
        }
        guard fields.count == 3, fields[0] == "POST",
            fields[1].hasPrefix("/install/"), fields[2] == "HTTP/1.1"
        else {
            respond(fd, status: "404 Not Found")
            return
        }
        let path = String(fields[1]).split(separator: "/")
        guard path.count == 3,
            let count = text.components(separatedBy: "\r\n")
                .dropFirst().first(where: { $0.lowercased().hasPrefix("content-length:") })
                .flatMap({ Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }),
            count > 0, count <= 512 * 1024 * 1024
        else {
            respond(fd, status: "400 Bad Request")
            return
        }
        let uuid = String(path[1])
        let kind = String(path[2])
        let presented = text.components(separatedBy: "\r\n").dropFirst()
            .first(where: { $0.lowercased().hasPrefix("x-openvm-token:") })
            .map { $0.dropFirst("x-openvm-token:".count).trimmingCharacters(in: .whitespaces) }
        guard let expected = token(for: uuid), let presented,
            Self.tokensMatch(expected, presented)
        else {
            respond(fd, status: "403 Forbidden")
            return
        }
        guard kind == "kernel" || kind == "initramfs",
            let record = try? registry.resolve(uuid), let diskPath = record.diskPath
        else {
            respond(fd, status: "404 Not Found")
            return
        }
        let destination = URL(fileURLWithPath: diskPath)
            .appendingPathExtension("openvm-\(kind)").path
        let temporary = destination + ".tmp"
        let out = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard out >= 0 else {
            respond(fd, status: "500 Internal Server Error")
            return
        }
        defer {
            Darwin.close(out)
            try? FileManager.default.removeItem(atPath: temporary)
        }
        var remaining = count
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let amount = min(remaining, buffer.count)
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, amount)
            }
            guard n > 0 else {
                respond(fd, status: "400 Bad Request")
                return
            }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { raw in
                    Darwin.write(out, raw.baseAddress!.advanced(by: written), n - written)
                }
                guard w > 0 else {
                    respond(fd, status: "500 Internal Server Error")
                    return
                }
                written += w
            }
            remaining -= n
        }
        guard fsync(out) == 0,
            rename(temporary, destination) == 0
        else {
            respond(fd, status: "500 Internal Server Error")
            return
        }
        respond(fd, status: "201 Created")
    }

    private func respond(_ fd: Int32, status: String) {
        let body = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = body.withCString { Darwin.write(fd, $0, strlen($0)) }
    }

    private static func ioError(_ operation: String) -> GuestBootError {
        .failure("artifact receiver \(operation): \(String(cString: strerror(errno)))")
    }
}
