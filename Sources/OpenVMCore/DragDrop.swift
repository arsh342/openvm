// The rules for files dragged into a guest.
import Foundation

/// Files dragged into a guest. The host stages copies, exposes them
/// as a temporary read-only share, and the guest agent copies them to the user's
/// Desktop; `status` is polled so a large tree never holds the channel.
public nonisolated enum DragDrop {
    /// The most items one drop can carry.
    public static let maxItems = 64

    /// A dropped item's name, as the guest will see it. Unicode and spaces are
    /// ordinary here; what is refused could escape the folder or corrupt the
    /// agent's one-name-per-line results.
    public static func validItemName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255, name != ".", name != ".." else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The names a set of host paths will have in the guest, or why they cannot.
    public static func itemNames(for paths: [String]) -> Result<[String], DropError> {
        guard !paths.isEmpty else { return .failure(.nothingToDrop) }
        guard paths.count <= maxItems else { return .failure(.tooManyItems) }
        var seen = Set<String>()
        var names: [String] = []
        for path in paths {
            // macOS paths come back decomposed; guests expect the composed form.
            let name = URL(fileURLWithPath: path).lastPathComponent.precomposedStringWithCanonicalMapping
            guard validItemName(name) else { return .failure(.badName(name)) }
            guard seen.insert(name).inserted else { return .failure(.duplicateName(name)) }
            names.append(name)
        }
        return .success(names)
    }

    /// What a `status` reply says.
    public static func status(_ reply: CBOR) -> DropStatus? {
        guard case .map(let fields) = reply,
            case .bool(let done)? = fields.first(where: { $0.key == "done" })?.value
        else { return nil }
        var placed: [String] = []
        if case .array(let rows)? = fields.first(where: { $0.key == "placed" })?.value {
            for case .text(let name) in rows { placed.append(name) }
        }
        var bytes: UInt64 = 0
        if case .uint(let n)? = fields.first(where: { $0.key == "bytes" })?.value { bytes = n }
        var error: String?
        if case .text(let message)? = fields.first(where: { $0.key == "error" })?.value { error = message }
        return DropStatus(done: done, placed: placed, bytes: bytes, error: error)
    }
}

/// Why a drop was refused before it started.
public nonisolated enum DropError: Error, Equatable, CustomStringConvertible, Sendable {
    case nothingToDrop, tooManyItems
    case badName(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .nothingToDrop: return "nothing to drop"
        case .tooManyItems: return "a drop takes at most \(DragDrop.maxItems) items"
        case .badName(let name): return "cannot drop a file named \(name.debugDescription)"
        case .duplicateName(let name): return "two dropped items are both named \(name.debugDescription)"
        }
    }
}

/// What a guest reports about a running drop.
public nonisolated struct DropStatus: Sendable, Equatable {
    public let done: Bool
    public let placed: [String]
    public let bytes: UInt64
    public let error: String?

    public init(done: Bool, placed: [String], bytes: UInt64, error: String?) {
        self.done = done
        self.placed = placed
        self.bytes = bytes
        self.error = error
    }
}
