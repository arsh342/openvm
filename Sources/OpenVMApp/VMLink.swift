// VMLink — `openvm://vm/<name or uuid>` opens that VM's window. A link names a VM and
// nothing else: no action, no query, so following one can never change anything.
import Foundation
import OpenVMCore

/// The VM a link names, or nil for any link that is not exactly that shape.
func vmReference(from url: URL) -> String? {
    guard url.scheme == "openvm", url.host == "vm", url.query == nil, url.fragment == nil else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    guard parts.count == 1, let reference = parts.first else { return nil }
    if VmRegistry.validName(reference) || UUID(uuidString: reference) != nil { return reference }
    return nil
}
