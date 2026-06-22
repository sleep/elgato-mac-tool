import Foundation

/// Local wall-clock timestamp ("HH:mm:ss.SSS") for console log lines.
/// Uses `localtime_r` (reentrant / thread-safe) plus integer milliseconds, so it
/// is cheap and safe to call from any capture/encoder thread — unlike a shared
/// `DateFormatter`, which is not thread-safe.
public func logTimestamp() -> String {
    let now = Date().timeIntervalSince1970
    let whole = Int(now)
    let millis = Int((now - Double(whole)) * 1000)
    var t = time_t(whole)
    var parts = tm()
    localtime_r(&t, &parts)
    return String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, millis)
}

/// Module-level shadow of Swift's `print` that prefixes every console line with a
/// timestamp. Unqualified `print(...)` calls in this module resolve to this
/// function (a local declaration outranks the imported stdlib one); we forward to
/// `Swift.print`, so all existing call sites get stamped without any edits.
///
/// NOTE: a shadow only applies within its own module. The `elgato-capture` and
/// `elgato-capture-gui` targets each define their own copy.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print("[\(logTimestamp())] \(message)", terminator: terminator)
}
