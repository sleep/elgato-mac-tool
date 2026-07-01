import CoreMediaIO
import CoreMedia
import Foundation

/// Sets a UVC capture device's frame rate through CoreMediaIO.
///
/// Why this exists: on devices like the Elgato HD60X, AVFoundation's
/// `activeVideoMinFrameDuration` is accepted but does nothing — the API can only
/// cap/drop frames from a source, not command the hardware to produce more. The
/// hardware's production rate is the CoreMediaIO stream property
/// `kCMIOStreamPropertyFrameRate`, which defaults to the device's slowest rate
/// (25fps) until something sets it. Elgato's own app sets exactly this property;
/// because it's device-global, doing so flips every open session to 60fps. This
/// helper does the same thing so we don't need their app running.
public enum CMIOFrameRate {

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func cfStringProperty(_ object: CMIOObjectID,
                                         _ selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard CMIOObjectHasProperty(object, &addr) else { return nil }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == 0 else { return nil }
        var out: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &out)
        guard status == 0, let out else { return nil }
        return out.takeRetainedValue() as String
    }

    /// Find the CMIO device whose UID matches the given AVCaptureDevice.uniqueID.
    private static func findDevice(uniqueID: String) -> CMIOObjectID? {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, size, &used, &devices) == 0 else { return nil }

        for device in devices {
            if cfStringProperty(device, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == uniqueID {
                return device
            }
        }
        return nil
    }

    /// Return the device's stream IDs (input streams come first for capture devices).
    private static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        var addr = address(CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOStreamID>.size
        guard count > 0 else { return [] }
        var ids = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, &ids) == 0 else { return [] }
        return ids
    }

    /// The frame rates the stream advertises as available.
    private static func availableFrameRates(_ stream: CMIOStreamID) -> [Float64] {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRates))
        guard CMIOObjectHasProperty(stream, &addr) else { return [] }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(stream, &addr, 0, nil, &size) == 0 else { return [] }
        let count = Int(size) / MemoryLayout<Float64>.size
        guard count > 0 else { return [] }
        var rates = [Float64](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, size, &used, &rates) == 0 else { return [] }
        return rates
    }

    private static func currentFrameRate(_ stream: CMIOStreamID) -> Float64? {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate))
        guard CMIOObjectHasProperty(stream, &addr) else { return nil }
        var value: Float64 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(stream, &addr, 0, nil,
                                               UInt32(MemoryLayout<Float64>.size), &used, &value)
        return status == 0 ? value : nil
    }

    /// Set the device's stream frame rate to the advertised rate closest to `targetFPS`.
    ///
    /// Returns the rate actually in effect after the set (read back from the device),
    /// or nil if the device/stream/property couldn't be found or set. Safe to call
    /// while an AVCaptureSession is running on the same device — the property is
    /// device-global, which is the whole point.
    @discardableResult
    public static func setFrameRate(deviceUniqueID: String, targetFPS: Double) -> Double? {
        guard let device = findDevice(uniqueID: deviceUniqueID) else {
            print("[CMIO] No CoreMediaIO device for uniqueID \(deviceUniqueID)")
            return nil
        }
        guard let stream = streams(of: device).first else {
            print("[CMIO] Device \(deviceUniqueID) has no streams")
            return nil
        }

        let available = availableFrameRates(stream)
        // Snap to the closest advertised rate. We must send a value the device
        // actually offers (its "60fps" is really 60.00024) or the set is rejected.
        let desired = available.min(by: { abs($0 - targetFPS) < abs($1 - targetFPS) }) ?? targetFPS

        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate))
        var settable: DarwinBoolean = false
        guard CMIOObjectHasProperty(stream, &addr),
              CMIOObjectIsPropertySettable(stream, &addr, &settable) == 0,
              settable.boolValue else {
            print("[CMIO] FrameRate property not settable on \(deviceUniqueID)")
            return nil
        }

        var value = Float64(desired)
        let status = CMIOObjectSetPropertyData(stream, &addr, 0, nil,
                                               UInt32(MemoryLayout<Float64>.size), &value)
        guard status == 0 else {
            print("[CMIO] Failed to set frame rate (\(desired)fps): OSStatus \(status)")
            return nil
        }

        let readback = currentFrameRate(stream) ?? desired
        print("[CMIO] Set frame rate → \(String(format: "%.3f", readback))fps (requested \(Int(targetFPS)), available \(available.map { Int($0.rounded()) }))")
        return readback
    }

    // Expose the lookups the controller needs (same file, so `private` is reachable,
    // but name them here for clarity of what the controller depends on).
    fileprivate static func resolve(deviceUniqueID: String) -> (device: CMIOObjectID, stream: CMIOStreamID, available: [Float64])? {
        guard let device = findDevice(uniqueID: deviceUniqueID),
              let stream = streams(of: device).first else { return nil }
        return (device, stream, availableFrameRates(stream))
    }

    fileprivate static func readFrameRate(_ stream: CMIOStreamID) -> Float64? {
        currentFrameRate(stream)
    }

    fileprivate static func frameRateAddress() -> CMIOObjectPropertyAddress {
        address(CMIOObjectPropertySelector(kCMIOStreamPropertyFrameRate))
    }
}

/// Keeps a UVC device pinned to a target frame rate for the lifetime of a capture
/// session.
///
/// One-shot setting isn't enough: the CoreMediaIO DAL plugin resets the stream's
/// frame rate back to the device default (25fps on the HD60X) when a session's
/// stream (re)starts — which races with, and clobbers, a set issued right after
/// `startRunning()`. So instead we register a property listener and RE-ASSERT the
/// target whenever the rate drops below it. That survives the startup reset window
/// and any later renegotiation (device reconnect, format change) with no sleeps.
public final class CMIOFrameRateController {

    private let queue = DispatchQueue(label: "capture.cmio.framerate")
    private var stream: CMIOStreamID = 0
    private var address = CMIOObjectPropertyAddress()
    private var listener: CMIOObjectPropertyListenerBlock?
    /// The exact advertised rate we're driving toward (e.g. 60.00024, not 60.0).
    private var desired: Float64 = 0

    public init() {}

    /// Begin driving `deviceUniqueID` to the advertised rate closest to `targetFPS`.
    /// Safe to call repeatedly; each call tears down any previous listener first.
    public func start(deviceUniqueID: String, targetFPS: Double) {
        stop()
        guard let resolved = CMIOFrameRate.resolve(deviceUniqueID: deviceUniqueID) else {
            print("[CMIO] Controller: no device/stream for \(deviceUniqueID)")
            return
        }
        stream = resolved.stream
        desired = resolved.available.min(by: { abs($0 - targetFPS) < abs($1 - targetFPS) }) ?? Float64(targetFPS)
        address = CMIOFrameRate.frameRateAddress()

        apply()  // set it once up front

        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reassertIfNeeded()
        }
        listener = block
        let status = CMIOObjectAddPropertyListenerBlock(stream, &address, queue, block)
        if status != 0 {
            print("[CMIO] Controller: failed to add listener (OSStatus \(status))")
            listener = nil
        } else {
            print("[CMIO] Controller: pinning \(String(format: "%.3f", desired))fps with self-healing listener")
        }
    }

    /// Stop driving the rate and remove the listener.
    public func stop() {
        if let block = listener {
            CMIOObjectRemovePropertyListenerBlock(stream, &address, queue, block)
            listener = nil
        }
        stream = 0
        desired = 0
    }

    /// Listener callback: if the DAL reset the rate below our target, put it back.
    /// Comparing against `desired - 1` avoids a feedback loop from our own set
    /// (readback is the snapped value, e.g. 60.00024 for a target of 60).
    private func reassertIfNeeded() {
        guard stream != 0, desired > 0 else { return }
        let current = CMIOFrameRate.readFrameRate(stream) ?? 0
        if current < desired - 1.0 {
            apply()
        }
    }

    private func apply() {
        guard stream != 0, desired > 0 else { return }
        var value = desired
        let status = CMIOObjectSetPropertyData(stream, &address, 0, nil,
                                               UInt32(MemoryLayout<Float64>.size), &value)
        if status != 0 {
            print("[CMIO] Controller: set failed (OSStatus \(status))")
        }
    }
}
