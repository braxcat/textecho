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
    var onTriggerDown: (() -> Void)?
    var onTriggerUp: (() -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?

    private var manager: IOHIDManager?
    private var connected = false
    private var retryTimer: Timer?
    private var retryInterval: TimeInterval = 3.0
    private var retryCount: Int = 0

    // Force click state tracking
    private var clickStage: Int = 0   // 0=none, 1=normal click, 2=force click
    private var triggerActive = false

    // Right-click state tracking
    private var rightButtonDown = false

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
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceConnected(device)
        }, selfPtr)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceDisconnected()
        }, selfPtr)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            AppLogger.shared.info("Magic Trackpad monitor started")
        } else {
            AppLogger.shared.error("Failed to open HID manager for trackpad: \(result)")
        }

        startRetryTimer()
    }

    func stop() {
        stopRetryTimer()
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        connected = false
        clickStage = 0
        triggerActive = false
        rightButtonDown = false
    }

    deinit {
        stop()
    }

    // MARK: - Device lifecycle

    private func deviceConnected(_ device: IOHIDDevice) {
        connected = true
        clickStage = 0
        triggerActive = false
        rightButtonDown = false
        stopRetryTimer()
        retryInterval = 3.0
        retryCount = 0
        AppLogger.shared.info("Magic Trackpad connected")
        onConnectionChanged?(true)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<TrackpadMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleInputValue(value)
        }, selfPtr)
    }

    private func deviceDisconnected() {
        connected = false
        clickStage = 0
        // Release trigger if active when device disconnects
        if triggerActive {
            triggerActive = false
            onTriggerUp?()
        }
        rightButtonDown = false
        AppLogger.shared.info("Magic Trackpad disconnected")
        onConnectionChanged?(false)
        startRetryTimer()
    }

    // MARK: - HID input value handling

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        switch gesture {
        case .forceClick:
            handleForceClick(usagePage: usagePage, usage: usage, value: intValue)
        case .rightClick:
            handleRightClick(usagePage: usagePage, usage: usage, value: intValue)
        }
    }

    /// Force click detection via digitizer click stage.
    /// Apple trackpads report: stage 0 = no click, 1 = normal, 2 = force click.
    /// We also check button usage page for the click stage transition.
    private func handleForceClick(usagePage: UInt32, usage: UInt32, value: Int) {
        // Digitizer page — look for click/touch pressure or stage
        // Usage 0x30 = Tip Pressure, 0x3D = Touch Type, various button usages
        // Apple encodes force click as button with stage info
        if usagePage == 0x0D { // kHIDPage_Digitizer
            // Some trackpads report stage via digitizer quality or touch type
            return
        }

        // Button page — Apple Magic Trackpad reports force click as button events
        // Button 1 (usage 1) = normal click, but force click triggers a distinct stage
        if usagePage == 0x09 { // kHIDPage_Button
            if usage == 1 { // Primary button
                let newStage = value > 0 ? 1 : 0
                handleStageTransition(newStage)
            }
            // Usage for force click stage varies; some models use button 6 or
            // report via GenericDesktop with a specific usage
            return
        }

        // Generic Desktop page — some trackpads report click count/stage here
        if usagePage == 0x01 { // kHIDPage_GenericDesktop
            // System-defined usages for click stage
            return
        }
    }

    private func handleStageTransition(_ newStage: Int) {
        let oldStage = clickStage
        clickStage = newStage

        // Normal click down → potential force click
        // Force click fires when we detect sustained hard press
        // For now, use button down as trigger since IOKit stage detection
        // varies across trackpad firmware versions
        if newStage == 1 && oldStage == 0 {
            // Normal click — don't trigger yet, wait for force indication
            // However, IOKit may not reliably report stage 2 on all models.
            // If we detect a button down, start trigger immediately for now.
            // TODO: Refine with pressure/stage detection once we can test on hardware
            if !triggerActive {
                triggerActive = true
                AppLogger.shared.info("Trackpad force click DOWN")
                onTriggerDown?()
            }
        } else if newStage == 0 && oldStage > 0 {
            if triggerActive {
                triggerActive = false
                AppLogger.shared.info("Trackpad force click UP")
                onTriggerUp?()
            }
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
                onTriggerDown?()
            } else {
                AppLogger.shared.info("Trackpad right-click UP")
                onTriggerUp?()
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
            guard let self, !self.connected, let manager = self.manager else { return }
            self.retryCount += 1
            if self.retryCount == 1 || self.retryCount % 10 == 0 {
                AppLogger.shared.info("Magic Trackpad: scanning for device... (attempt \(self.retryCount))")
            }
            let matchDict: [String: Any] = [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: Self.productID,
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
