/// The guest display modes a host may ask for.
public nonisolated enum GuestDisplay {
    /// The range the agents accept: below this a desktop is unusable, above it
    /// is past what the framework's scanout takes.
    public static func validMode(width: UInt64, height: UInt64) -> Bool {
        (640...7680).contains(width) && (480...4320).contains(height)
    }

    /// Whole scales only: Retina is 2x, and 3x is the most a host asks for.
    public static func validScale(_ scale: UInt64) -> Bool { (1...3).contains(scale) }

    /// The scale a `displayReply` says the guest holds, nil when none was asked for.
    public static func heldScale(_ reply: CBOR) -> UInt64? {
        guard case .map(let fields) = reply,
            case .uint(let scale)? = fields.first(where: { $0.key == "scale" })?.value
        else { return nil }
        return scale
    }

    /// The mode a `displayReply` says the guest holds.
    public static func heldMode(_ reply: CBOR) -> (width: UInt64, height: UInt64)? {
        guard case .map(let fields) = reply,
            case .uint(let width)? = fields.first(where: { $0.key == "width" })?.value,
            case .uint(let height)? = fields.first(where: { $0.key == "height" })?.value
        else {
            return nil
        }
        return (width, height)
    }
}
