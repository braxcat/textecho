import Foundation
import IOKit
import IOKit.hid

/// Which gesture on the Magic Trackpad triggers dictation.
enum TrackpadGesture: Int, Codable {
    case forceClick = 0
    case rightClick = 1
}

/// Monitors an external Apple Magic Trackpad via IOKit HID and fires
/// trigger callbacks on force click or right-click gestures.
///
/// Matches all connected Magic Trackpads by vendor/product ID (not Bluetooth
/// address), so re-pairing and different trackpads work automatically.
///
/// Bluetooth: VID 0x004C (Apple), PID 0x0265 (Magic Trackpad)
final class TrackpadMonitor {
    static let vendorID = 0x004C  // Apple
    static let productID = 0x0265 // Magic Trackpad

    var gesture: TrackpadGesture = .forceClick
    private var _onTriggerDown: (() -> Void)?
    var onTriggerDown: (() -> Void)? {
        get { _onTriggerDown }
        set {
            guard let newValue else { _onTriggerDown = nil; return }
            _onTriggerDown = {
                DispatchQueue.main.async { newValue() }
            }
        }
    }
    private var _onTriggerUp: (() -> Void)?
    var onTriggerUp: (() -> Void)? {
        get { _onTriggerUp }
        set {
            guard let newValue else { _onTriggerUp = nil; return }
            _onTriggerUp = {
                DispatchQueue.main.async { newValue() }
            }
        }
    }
    private var _onConnectionChanged: ((Bool) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)? {
        get { _onConnectionChanged }
        set {
            guard let newValue else { _onConnectionChanged = nil; return }
            _onConnectionChanged = { connected in
                DispatchQueue.main.async { newValue(connected) }
            }
        }
    }

    private var manager: IOHIDManager?
    private var connectedDevices: Set<IOHIDDevice> = []
    private var retryTimer: Timer?
    private var retryInterval: TimeInterval = 3.0
    private var retryCount: Int = 0
    private var monitorThread: Thread?
    private var monitorRunLoop: CFRunLoop?

    // Force click state tracking
    private var clickStage: Int = 0   // 0=none, 1=normal click, 2=force click
    private var triggerActive = false

    // Right-click state tracking
    private var rightButtonDown = false

    var isConnected: Bool { !connectedDevices.isEmpty }

    func start() {
        guard manager == nil, monitorThread == nil else { return }

        let sem = DispatchSemaphore(value: 0)
        monitorThread = Thread { [weak self] in
            guard let self else { sem.signal(); return }
            guard let runLoop = CFRunLoopGetCurrent() else {
                sem.signal()
                return
            }
            self.monitorRunLoop = runLoop
            self.startManager(on: runLoop)
            sem.signal()
            CFRunLoopRun()
        }
        monitorThread?.name = "com.textecho.trackpad"
        monitorThread?.qualityOfService = .userInteractive
        monitorThread?.start()
        sem.wait()
    }

    func stop() {
        stopManager()
    }

    private func stopFromMonitorThread() {
        stopRetryTimer()

        if let manager, let runLoop = monitorRunLoop {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        }

        manager = nil
        connectedDevices.removeAll()
        clickStage = 0
        triggerActive = false
        rightButtonDown = false

        if let runLoop = monitorRunLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private func startManager(on runLoop: CFRunLoop) {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Match Apple Magic Trackpad over Bluetooth only — skip built-in trackpad (SPI)
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDTransportKey as String: "Bluetooth",
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceConnected(device)
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceDisconnected(device)
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            AppLogger.shared.info("Magic Trackpad monitor started")
        } else {
            AppLogger.shared.error("Failed to open HID manager for trackpad: \(result)")
        }

        startRetryTimer()
    }

    private func stopManager() {
        guard monitorThread != nil, let runLoop = monitorRunLoop else { return }

        let sem = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in
            stopFromMonitorThread()
            sem.signal()
        }
        CFRunLoopWakeUp(runLoop)
        sem.wait()
        self.monitorThread = nil
        self.monitorRunLoop = nil
    }

    deinit {
        stop()
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        // Skip if already tracking this device (multiple HID interfaces per physical device)
        guard !connectedDevices.contains(device) else { return }

        // Verify this is actually a Bluetooth device (double-check transport)
        if let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String {
            AppLogger.shared.info("Magic Trackpad device transport: \(transport)")
            guard transport.lowercased().contains("bluetooth") else {
                AppLogger.shared.info("Skipping non-Bluetooth trackpad device (transport: \(transport))")
                return
            }
        }

        connectedDevices.insert(device)
        clickStage = 0
        triggerActive = false
        rightButtonDown = false
        stopRetryTimer()
        retryInterval = 3.0
        retryCount = 0
        AppLogger.shared.info("Magic Trackpad connected (devices: \(connectedDevices.count))")
        _onConnectionChanged?(true)

        // Filter to button + digitizer pages (skip generic desktop / touch coordinates)
        // Using multiple match via array of dicts
        let buttonMatch: [[String: Any]] = [
            [kIOHIDElementUsagePageKey as String: 0x09], // kHIDPage_Button
            [kIOHIDElementUsagePageKey as String: 0x0D], // kHIDPage_Digitizer
        ]
        IOHIDDeviceSetInputValueMatchingMultiple(device, buttonMatch as CFArray)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleInputValue(value)
        }, selfPtr)
    }

    private func deviceDisconnected(_ device: IOHIDDevice) {
        connectedDevices.remove(device)
        AppLogger.shared.info("Magic Trackpad disconnected (devices: \(connectedDevices.count))")
        if connectedDevices.isEmpty {
            clickStage = 0
            if triggerActive {
                triggerActive = false
                _onTriggerUp?()
            }
            rightButtonDown = false
            _onConnectionChanged?(false)
            startRetryTimer()
        }
    }

    // MARK: - HID input value handling

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // Debug: log all incoming HID values to understand what the trackpad reports
        AppLogger.shared.info("Trackpad HID: page=0x\(String(usagePage, radix: 16)) usage=0x\(String(usage, radix: 16)) value=\(intValue)")

        switch gesture {
        case .forceClick:
            handleForceClick(usagePage: usagePage, usage: usage, value: intValue)
        case .rightClick:
            handleRightClick(usagePage: usagePage, usage: usage, value: intValue)
        }
    }

    /// Force click detection via button events.
    /// Apple Magic Trackpad reports button 1 for normal click.
    /// Force click (deep press) triggers button 2 on some models, or
    /// a distinct button event. We use button 1 as trigger since we're
    /// only monitoring the external trackpad — normal clicks on this
    /// device are dedicated to TextEcho when enabled.
    private func handleForceClick(usagePage: UInt32, usage: UInt32, value: Int) {
        guard usagePage == 0x09 else { return } // kHIDPage_Button

        // Button 1 = primary click (force click also triggers this)
        guard usage == 1 else { return }

        let pressed = value > 0
        if pressed && !triggerActive {
            triggerActive = true
            AppLogger.shared.info("Trackpad force click DOWN")
            _onTriggerDown?()
        } else if !pressed && triggerActive {
            triggerActive = false
            AppLogger.shared.info("Trackpad force click UP")
            _onTriggerUp?()
        }
    }

    /// Right-click detection via HID button 2.
    private func handleRightClick(usagePage: UInt32, usage: UInt32, value: Int) {
        guard usagePage == 0x09 else { return } // kHIDPage_Button
        guard usage == 2 else { return }        // Button 2 = right click

        let pressed = value > 0
        if pressed != rightButtonDown {
            rightButtonDown = pressed
            if pressed {
                AppLogger.shared.info("Trackpad right-click DOWN")
                _onTriggerDown?()
            } else {
                AppLogger.shared.info("Trackpad right-click UP")
                _onTriggerUp?()
            }
        }
    }

    // MARK: - Retry timer (exponential backoff)

    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        scheduleNextRetry()
    }

    private func scheduleNextRetry() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: false) { [weak self] _ in
            guard let self, self.connectedDevices.isEmpty, let manager = self.manager else { return }
            self.retryCount += 1
            if self.retryCount == 1 || self.retryCount % 10 == 0 {
                AppLogger.shared.info("Magic Trackpad: scanning for device... (attempt \(self.retryCount))")
            }
            let matchDict: [String: Any] = [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: Self.productID,
                kIOHIDTransportKey as String: "Bluetooth",
            ]
            IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
            self.retryInterval = min(self.retryInterval * 2, 60.0)
            self.scheduleNextRetry()
        }
    }

    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
}
