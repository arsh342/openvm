// LinuxISOCheck — whether an ISO can start on this Mac. The guest must be ARM64 and boot by UEFI, which
// the removable-media boot files show. This looks only at their names, and it never refuses an ISO
// where it finds neither: it may still boot.
import Foundation

public nonisolated enum LinuxISOCheck {
    public enum Verdict: Equatable, Sendable {
        case usable, x86Only, unknown

        /// Why the ISO cannot be used. An unknown ISO may well work, so it has none.
        public var problem: String? {
            self == .x86Only
                ? "This ISO is for Intel and AMD PCs. A Mac with Apple silicon runs ARM64 guests only: download the ARM64 (aarch64) version."
                : nil
        }
    }

    /// A disk image is whole 512-byte sectors, so any other size means the file was cut off.
    public static func sizeProblem(bytes: UInt64) -> String? {
        bytes > 0 && bytes % 512 == 0
            ? nil : "This ISO looks incomplete: its size is not a whole number of disk sectors. Download it again."
    }

    /// `efiBootFiles` are the boot file names found in the ISO.
    public static func verdict(efiBootFiles: Set<String>) -> Verdict {
        let names = Set(efiBootFiles.map { $0.lowercased() })
        if names.contains("bootaa64.efi") { return .usable }
        return names.contains("bootx64.efi") ? .x86Only : .unknown
    }
}
