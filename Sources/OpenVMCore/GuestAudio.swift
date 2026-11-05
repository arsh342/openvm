/// What an `audioReply` says about the guest's sound.
public nonisolated struct GuestAudioStatus: Sendable, Equatable {
    /// The sound card the guest sees, nil when it has none.
    public let device: String?
    /// Nil when the guest cannot tell, which is Windows.
    public let running: Bool?
    public let rate: UInt64
    /// Whether sound is switched on, where that is a choice: off, pending, on or failed.
    public let state: String?

    public init(device: String?, running: Bool?, rate: UInt64, state: String? = nil) {
        self.device = device
        self.running = running
        self.rate = rate
        self.state = state
    }

    public init?(_ reply: CBOR) {
        guard case .map(let fields) = reply else { return nil }
        var running: Bool?
        if case .bool(let value)? = fields.first(where: { $0.key == "running" })?.value { running = value }
        var state: String?
        if case .text(let word)? = fields.first(where: { $0.key == "state" })?.value { state = word }
        guard running != nil || state != nil else { return nil }
        var device: String?
        if case .text(let name)? = fields.first(where: { $0.key == "device" })?.value { device = name }
        var rate: UInt64 = 0
        if case .uint(let n)? = fields.first(where: { $0.key == "rate" })?.value { rate = n }
        self.init(device: device, running: running, rate: rate, state: state)
    }
}
