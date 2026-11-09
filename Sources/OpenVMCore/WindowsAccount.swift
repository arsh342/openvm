// WindowsAccount — the account a Windows guest is created with: what Windows accepts, and how a
// password reaches the answer file. The password is the person's, so nothing here logs or keeps it.
import Foundation

public nonisolated enum WindowsAccount {
    /// The guest's computer name. Never the same as an account's: Windows does not allow that, and a
    /// lookup of the name can then find the computer instead of the user.
    public static let computerName = "OPENVM-GUEST"
    public static let defaultName = "openvm"
    public static let defaultPassword = "openvm"

    private static let reserved: Set<String> = ["administrator", "guest", "defaultaccount", "wdagutilityaccount"]

    /// Why Windows would not take this as an account name, or nil. Stricter than Windows on purpose:
    /// the name also goes into a script, so only plain characters are allowed.
    public static func nameProblem(_ name: String) -> String? {
        guard !name.isEmpty else { return "Choose a user name." }
        guard name.count <= 20 else { return "A Windows user name can have at most 20 characters." }
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "Use only letters, digits, dots, dashes and underscores in the user name."
        }
        guard !name.hasSuffix(".") else { return "A Windows user name cannot end with a dot." }
        let lower = name.lowercased()
        if reserved.contains(lower) { return "Windows keeps the name \(name) for itself." }
        if lower == computerName.lowercased() { return "The user name cannot be the same as the computer's." }
        return nil
    }

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// Why this password cannot be used, or nil.
    public static func passwordProblem(_ password: String, confirm: String) -> String? {
        guard !password.isEmpty else { return "Choose a password." }
        guard password.count <= 127 else { return "A Windows password can have at most 127 characters." }
        guard !password.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return "A password cannot contain control characters."
        }
        return password == confirm ? nil : "The passwords do not match."
    }

    /// The value for the answer file's template, written for the `sed` in mk-windows-media.sh: escaped
    /// for XML first, then for a `s|...|...|` replacement.
    public static func templateValue(_ value: String) -> String {
        var xml = ""
        for character in value {
            switch character {
            case "&": xml += "&amp;"
            case "<": xml += "&lt;"
            case ">": xml += "&gt;"
            default: xml.append(character)
            }
        }
        var out = ""
        for character in xml {
            if character == "\\" || character == "&" || character == "|" { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
