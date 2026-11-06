// VmSummary — one row of the host's `list`, as a window shows it.
import Foundation

public nonisolated struct VmSummary: Sendable, Equatable, Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    public let state: VmState
    /// What the host is doing to the VM right now ("start", "stop", …), nil when idle.
    public let activity: String?
    public let bootMode: BootMode
    public let cpus: Int
    public let memoryMB: Int
    /// The disk's size as the guest sees it.
    public let diskBytes: UInt64?
    public let timezone: String?
    /// A Windows install is running for this VM. Quitting would stop it.
    public let installing: Bool
    /// Files are being copied into this VM. Quitting would cut them off.
    public let dropping: Bool

    /// Rows from an older host lack the newer fields, and still decode.
    public init?(row: CBOR) {
        guard case .map(let fields) = row,
            case .text(let name)? = fields.first(where: { $0.key == "name" })?.value,
            case .text(let uuid)? = fields.first(where: { $0.key == "uuid" })?.value,
            case .text(let stateName)? = fields.first(where: { $0.key == "state" })?.value,
            let state = VmState(rawValue: stateName)
        else { return nil }
        func text(_ key: String) -> String? {
            if case .text(let value)? = fields.first(where: { $0.key == key })?.value { return value }
            return nil
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let value)? = fields.first(where: { $0.key == key })?.value { return value }
            return false
        }
        func number(_ key: String) -> UInt64? {
            if case .uint(let value)? = fields.first(where: { $0.key == key })?.value { return value }
            return nil
        }
        self.uuid = uuid
        self.name = name
        self.state = state
        self.activity = text("activity")
        self.bootMode = text("bootMode").flatMap(BootMode.init(rawValue:)) ?? .linux
        self.cpus = Int(number("cpus") ?? 0)
        self.memoryMB = Int(number("memoryMB") ?? 0)
        self.diskBytes = number("diskBytes")
        self.timezone = text("timezone")
        self.installing = flag("installing")
        self.dropping = flag("dropping")
    }
}
