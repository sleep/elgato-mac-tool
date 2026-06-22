import Foundation
import CaptureCore

/// Timestamp-prefixing `print` shadow for this module. See
/// `CaptureCore/Logging.swift` for how the shadow works and why each target
/// needs its own copy. Reuses `CaptureCore.logTimestamp()` for the format.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print("[\(logTimestamp())] \(message)", terminator: terminator)
}
