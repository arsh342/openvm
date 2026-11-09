// StopIntent — whether a guest that has just stopped meant to restart.
//
// The framework reports a guest's restart as a stop: there is no reboot. Without help a VM that
// restarts itself (an update, `reboot`) would end up Stopped. A Linux guest says which it meant on its
// console, in a line its agent prints, and the console file belongs to one boot. A guest that says
// nothing is treated as powered off: guessing "restart" wrongly would boot a VM the person shut down.
import Foundation

nonisolated enum StopIntent: Equatable {
    case restart, powerOff, unknown

    var restarts: Bool { self == .restart }
}

/// The agent prints "going down: <runlevel>" when the guest stops it (OpenRC's own record of whether it is
// rebooting or shutting down). The kernel's "reboot: ..." lines are accepted too, though they were never
// seen on the console in a real run.
nonisolated func stopIntent(consoleTail: String) -> StopIntent {
    var result = StopIntent.unknown
    var best = consoleTail.startIndex
    let words: [(String, StopIntent)] = [
        ("going down: reboot", .restart), ("going down: shutdown", .powerOff), ("going down: halt", .powerOff),
        ("Restarting system", .restart), ("Power down", .powerOff), ("System halted", .powerOff),
    ]
    for (word, intent) in words {
        if let found = consoleTail.range(of: word, options: .backwards), found.lowerBound >= best {
            best = found.lowerBound
            result = intent
        }
    }
    return result
}

/// A limit on automatic restarts, so a guest that restarts the moment it boots cannot loop for ever.
nonisolated struct RestartBudget {
    let limit: Int
    let window: TimeInterval
    private var times: [Date] = []

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(at now: Date) -> Bool {
        times.removeAll { now.timeIntervalSince($0) >= window }
        guard times.count < limit else { return false }
        times.append(now)
        return true
    }
}

nonisolated final class RestartBudgets: @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [String: RestartBudget] = [:]

    func allow(_ uuid: String) -> Bool {
        lock.withLock {
            var budget = budgets[uuid] ?? RestartBudget(limit: 3, window: 300)
            let ok = budget.allow(at: Date())
            budgets[uuid] = budget
            return ok
        }
    }
}

nonisolated let restartBudgets = RestartBudgets()

/// The end of a boot's console, where the kernel's last words are.
nonisolated func consoleTail(for name: String, bytes: Int = 4096) -> String {
    let url = home.appendingPathComponent("\(name).console.log")
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
}
