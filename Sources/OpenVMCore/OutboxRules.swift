// OutboxRules — what the host accepts from a guest's outbox before moving it to the Mac.
//
// The outbox is a folder the guest writes into, so everything in it is untrusted: a name could try to
// leave the folder, an entry could be a link to a Mac file the guest cannot read, a device or pipe
// could hang the host. Nothing is followed and nothing special is accepted: plain files and folders
// only, found with lstat, within a size budget.
import Darwin
import Foundation

public nonisolated enum OutboxProblem: Error, Equatable, CustomStringConvertible, Sendable {
    case nothingToSend, tooManyItems, tooLarge
    case badName(String)
    case duplicate(String)
    case missing(String)
    /// A link, device, pipe or socket (the path inside the outbox).
    case notPlain(String)

    public var description: String {
        switch self {
        case .nothingToSend: return "the guest sent nothing"
        case .tooManyItems: return "the guest sent more than \(OutboxRules.maxItems) items"
        case .tooLarge: return "what the guest sent is larger than the space allowed"
        case .badName(let name): return "cannot accept a file named \(name.debugDescription)"
        case .duplicate(let name): return "two items are both named \(name.debugDescription)"
        case .missing(let name): return "\(name.debugDescription) is listed but not there"
        case .notPlain(let path): return "\(path.debugDescription) is not a plain file or folder"
        }
    }
}

public nonisolated enum OutboxRules {
    public static let maxItems = DragDrop.maxItems

    /// The items a `.ready` manifest names, as URLs under `root`, or why they cannot be taken.
    /// `maxBytes` bounds the total size of every file inside them.
    public static func vet(manifest: String, root: URL, maxBytes: UInt64) -> Result<[URL], OutboxProblem> {
        let names = manifest.split(separator: "\n", omittingEmptySubsequences: true).map {
            String($0).precomposedStringWithCanonicalMapping
        }
        guard !names.isEmpty else { return .failure(.nothingToSend) }
        guard names.count <= maxItems else { return .failure(.tooManyItems) }
        var seen = Set<String>()
        var items: [URL] = []
        var total: UInt64 = 0
        for name in names {
            guard DragDrop.validItemName(name) else { return .failure(.badName(name)) }
            guard seen.insert(name).inserted else { return .failure(.duplicate(name)) }
            let url = root.appendingPathComponent(name)
            switch measure(url, shown: name, budget: maxBytes &- total) {
            case .success(let bytes): total += bytes
            case .failure(let problem): return .failure(problem)
            }
            items.append(url)
        }
        return .success(items)
    }

    /// The bytes in a plain file, or in a folder and everything in it. Never follows a link.
    private static func measure(_ url: URL, shown: String, budget: UInt64) -> Result<UInt64, OutboxProblem> {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .failure(.missing(shown)) }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let size = UInt64(max(0, info.st_size))
            return size > budget ? .failure(.tooLarge) : .success(size)
        case S_IFDIR:
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return .failure(.notPlain(shown))
            }
            var sum: UInt64 = 0
            for child in names.sorted() {
                guard DragDrop.validItemName(child) else { return .failure(.badName(child)) }
                switch measure(url.appendingPathComponent(child), shown: shown + "/" + child, budget: budget &- sum) {
                case .success(let bytes): sum += bytes
                case .failure(let problem): return .failure(problem)
                }
            }
            return .success(sum)
        default:
            return .failure(.notPlain(shown))
        }
    }
}
