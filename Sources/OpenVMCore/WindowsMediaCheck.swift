// WindowsMediaCheck — is this ISO something openVM can build a Windows guest from? Decided from
// the names of its files, so the person is told at once instead of after a long build. The user
// brings their own ISO (openVM ships no Windows), so what they bring is checked.
import Foundation

public nonisolated enum MediaProblem: Error, Equatable, CustomStringConvertible, Sendable {
    case notWindows, notArm64, noInstallWim, onlyEsd

    public var description: String {
        switch self {
        case .notWindows:
            return "This does not look like a Windows installation ISO. Download Windows 11 (ARM64) from Microsoft and choose that."
        case .notArm64:
            return "This is not a Windows 11 ARM64 ISO. A Mac with Apple Silicon needs the ARM64 edition, not the x64 one."
        case .noInstallWim:
            return "This Windows ISO has no sources/install.wim, so there is no Windows image to install."
        case .onlyEsd:
            return "This ISO carries its Windows image as install.esd, which openVM cannot read. Use the ISO as Microsoft publishes it, with install.wim."
        }
    }
}

public nonisolated enum WindowsMediaCheck {
    /// `files` are paths inside the ISO, relative to its root, in any letter case.
    public static func verdict(files: Set<String>) -> Result<Void, MediaProblem> {
        let names = Set(files.map { $0.lowercased() })
        let looksLikeWindows = names.contains("sources/boot.wim") || names.contains("setup.exe") || names.contains("bootmgr")
        guard looksLikeWindows else { return .failure(.notWindows) }
        guard names.contains("efi/boot/bootaa64.efi") else { return .failure(.notArm64) }
        guard names.contains("sources/install.wim") else {
            return .failure(names.contains("sources/install.esd") ? .onlyEsd : .noInstallWim)
        }
        return .success(())
    }
}

extension WindowsMediaCheck {
    /// Why this ISO cannot be used, or nil when it can.
    public nonisolated static func problem(files: Set<String>) -> MediaProblem? {
        if case .failure(let problem) = verdict(files: files) { return problem }
        return nil
    }
}
