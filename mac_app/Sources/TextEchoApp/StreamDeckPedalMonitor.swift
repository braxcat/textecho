import Foundation
import IOKit
import IOKit.hid

/// Which physical pedal to use as the push-to-talk trigger.
enum PedalPosition: Int, Codable {
    case left = 0
    case center = 1
    case right = 2
}

/// Reads Elgato Stream Deck Pedal HID reports directly via IOKit.
/// Fires press/release callbacks for true push-to-talk — no Elgato software needed.
///
/// USB: VID 0x0FD9, PID 0x0086
/// HID report: 3 header bytes + 3 pedal state bytes (0x00=released, 0x01=pressed)
/// IOKit strips the report ID byte, so callback receives 6 bytes total.
final class StreamDeckPedalMonitor {
    static let vendorID = 0x0FD9
    static let productID = 0x0086
    private static let reportBufferSize = 8 // generous for 6-7 byte reports

    /// Per-pedal callbacks: index 0=left, 1=center, 2=right
    var onPedalDownByPosition: [Int: () -> Void] = [:]
    var onPedalUpByPosition: [Int: () -> Void] = [:]

    /// Legacy single-pedal callbacks (used if per-pedal not set)
    var onPedalDown: (() -> Void)?
    var onPedalUp: (() -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    var activePedal: PedalPosition = .center

    private var manager: IOHIDManager?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var pedalStates: [Bool] = [false, false, false]
    private var connected = false

    init() {
        reportBuffer = .allocate(capacity: Self.reportBufferSize)
        reportBuffer?.initialize(repeating: 0, count: Self.reportBufferSize)
    }

    deinit {
        stop()
        reportBuffer?.deallocate()
    }

    var isConnected: Bool { connected }

    func start() {
        guard manager == nil else { return }

        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager else { return }

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<StreamDeckPedalMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceConnected(device)
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<StreamDeckPedalMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceDisconnected()
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Open in shared (non-exclusive) mode. Seizing the device can freeze the
        // system if the app crashes while holding the seize, so we avoid it.
        // If Elgato software is running it may consume events — quit it first.
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            AppLogger.shared.info("Stream Deck Pedal monitor started (shared mode)")
        } else {
            AppLogger.shared.error("Failed to open HID manager: \(result)")
        }
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        connected = false
        pedalStates = [false, false, false]
    }

    private func deviceConnected(_ device: IOHIDDevice) {
        connected = true
        pedalStates = [false, false, false]
        AppLogger.shared.info("Stream Deck Pedal connected")
        onConnectionChanged?(true)

        guard let reportBuffer else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            Self.reportBufferSize,
            { context, _, _, _, _, data, length in
                guard let context else { return }
                let monitor = Unmanaged<StreamDeckPedalMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.handleReport(data, length: length)
            },
            selfPtr
        )
    }

    private func deviceDisconnected() {
        connected = false
        pedalStates = [false, false, false]
        AppLogger.shared.info("Stream Deck Pedal disconnected")
        onConnectionChanged?(false)
    }

    private func handleReport(_ data: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        // Log raw bytes for debugging
        let bytes = (0..<Int(length)).map { String(format: "%02x", data[$0]) }.joined(separator: " ")
        AppLogger.shared.info("Pedal HID report (\(length) bytes): \(bytes)")

        // Report format: [reportID, 0x00, keyCount, 0x00, left, center, right, 0x00]
        // Pedal states start at offset 4.
        let dataOffset = 4

        for i in 0..<3 {
            guard dataOffset + i < length else { continue }
            let pressed = data[dataOffset + i] != 0
            if pressed != pedalStates[i] {
                pedalStates[i] = pressed
                let name = ["left", "center", "right"][i]
                AppLogger.shared.info("Pedal \(name) \(pressed ? "DOWN" : "UP")")
                // Per-pedal callbacks take priority
                if let handler = pressed ? onPedalDownByPosition[i] : onPedalUpByPosition[i] {
                    handler()
                } else if i == activePedal.rawValue {
                    // Fall back to legacy single-pedal callbacks
                    if pressed {
                        onPedalDown?()
                    } else {
                        onPedalUp?()
                    }
                }
            }
        }
    }
}
