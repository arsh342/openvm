// OVMC frames: the fixed header, and a streaming decoder.
import Foundation

/// Wire version of the OVMC channel. Bump only per docs/guest-protocol.md versioning rules.
public nonisolated enum OVMC {
    public static let currentVersion: UInt16 = 1
    /// 1 MiB — the transport refuses anything larger; the file service chunks instead.
    public static let maxPayload = 1 << 20
    /// magic "OVMC"
    public static let magic = Data([0x4F, 0x56, 0x4D, 0x43])
    /// magic(4) + version(2) + type(2) + flags(2) + length(4)
    public static let headerSize = 14
}

/// A receiver stop rule that fired. The connection closes after any of these.
public nonisolated enum FrameError: Error, Equatable, Sendable {
    case badMagic  // not an OVMC frame
    case unsupportedVersion(UInt16)  // framing version we do not speak
    case reservedFlags(UInt16)  // v1 requires flags == 0
    case oversize(UInt32)  // length > OVMC.maxPayload
}

/// One length-prefixed channel frame. Immutable, Sendable.
public nonisolated struct Frame: Equatable, Sendable {
    public var version: UInt16
    public var type: UInt16  // MessageType.rawValue
    public var flags: UInt16
    public var payload: Data

    public init(
        version: UInt16 = OVMC.currentVersion, type: UInt16, flags: UInt16 = 0, payload: Data = Data()
    ) {
        precondition(payload.count <= OVMC.maxPayload, "payload must be ≤ OVMC.maxPayload")
        self.version = version
        self.type = type
        self.flags = flags
        self.payload = payload
    }

    /// Header, big-endian: magic | version | type | flags | length | payload…
    public func encoded() -> Data {
        var d = OVMC.magic
        d.append(contentsOf: Self.u16BE(version))
        d.append(contentsOf: Self.u16BE(type))
        d.append(contentsOf: Self.u16BE(flags))
        d.append(contentsOf: Self.u32BE(UInt32(payload.count)))
        d.append(payload)
        return d
    }

    static func u16BE(_ v: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
    static func u32BE(_ v: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v),
        ]
    }
    static func u16(_ d: Data, _ i: Int) -> UInt16 {
        UInt16(d[d.startIndex + i]) << 8 | UInt16(d[d.startIndex + i + 1])
    }
    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[d.startIndex + i]) << 24 | UInt32(d[d.startIndex + i + 1]) << 16
            | UInt32(d[d.startIndex + i + 2]) << 8 | UInt32(d[d.startIndex + i + 3])
    }
}

/// Streaming decoder: feed bytes as they arrive, take the frames that became whole.
/// Any validation failure clears the buffer and throws — the peer should treat that as
/// "stop this connection", per docs/guest-protocol.md.
public nonisolated struct FrameDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ bytes: Data) throws -> [Frame] {
        buffer.append(bytes)
        var out: [Frame] = []
        while buffer.count >= OVMC.headerSize {
            guard buffer.prefix(4) == OVMC.magic else {
                buffer = Data()
                throw FrameError.badMagic
            }
            let version = Frame.u16(buffer, 4)
            let flags = Frame.u16(buffer, 8)
            let length = Frame.u32(buffer, 10)
            if version != OVMC.currentVersion {
                buffer = Data()
                throw FrameError.unsupportedVersion(version)
            }
            if flags != 0 {
                buffer = Data()
                throw FrameError.reservedFlags(flags)
            }
            if length > UInt32(OVMC.maxPayload) {
                buffer = Data()
                throw FrameError.oversize(length)
            }
            let total = OVMC.headerSize + Int(length)
            guard buffer.count >= total else { break }  // payload still arriving
            let s = buffer.startIndex
            out.append(
                Frame(
                    version: version, type: Frame.u16(buffer, 6), flags: flags,
                    payload: buffer.subdata(in: (s + OVMC.headerSize)..<(s + total))))
            buffer.removeFirst(total)
        }
        return out
    }
}
