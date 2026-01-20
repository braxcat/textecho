#!/usr/bin/env python3
"""
macOS overlay window for dictation feedback.

Shows recording status, transcription progress, and LLM responses.
Uses AppKit for native macOS window with transparency.

IMPORTANT: All methods must be called from the main thread.
Use the schedule_* methods for thread-safe calls from background threads.
"""

import threading
import queue
import time
from typing import Optional, Callable

import objc
from Foundation import NSObject, NSMakeRect, NSThread, NSTimer
from AppKit import (
    NSEvent,
    NSWindow,
    NSView,
    NSColor,
    NSFont,
    NSTextField,
    NSBezierPath,
    NSScreen,
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSLineBreakByWordWrapping,
)

# Window constants
NSWindowStyleMaskBorderless = 0
NSBackingStoreBuffered = 2
kCGFloatingWindowLevel = 3


# Tokyo Night color scheme
class TokyoNight:
    BG = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.10, 0.11, 0.15, 0.95)
    BG_DARK = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.08, 0.09, 0.12, 0.95)
    FG = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.66, 0.70, 0.84, 1.0)
    RED = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.96, 0.45, 0.51, 1.0)
    GREEN = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.45, 0.82, 0.56, 1.0)
    YELLOW = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.88, 0.74, 0.45, 1.0)
    BLUE = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.48, 0.65, 0.94, 1.0)
    MAGENTA = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.73, 0.56, 0.94, 1.0)
    CYAN = NSColor.colorWithCalibratedRed_green_blue_alpha_(0.49, 0.85, 0.86, 1.0)


class RecordingIndicator(NSView):
    """Recording indicator dot."""

    def init(self):
        self = objc.super(RecordingIndicator, self).init()
        if self is None:
            return None
        self.is_recording = False
        return self

    def drawRect_(self, rect):
        """Draw the recording indicator."""
        if not self.is_recording:
            return

        TokyoNight.RED.setFill()
        bounds = self.bounds()
        size = min(bounds.size.width, bounds.size.height)
        circle_rect = NSMakeRect(
            (bounds.size.width - size) / 2,
            (bounds.size.height - size) / 2,
            size,
            size
        )
        path = NSBezierPath.bezierPathWithOvalInRect_(circle_rect)
        path.fill()

    def setRecording_(self, recording):
        """Set recording state and redraw."""
        self.is_recording = recording
        self.setNeedsDisplay_(True)


class DictationOverlay(NSObject):
    """
    Overlay window for dictation feedback.

    Thread Safety:
        - Call schedule_* methods from any thread (they queue work for main thread)
        - Call other methods only from main thread
        - Call process_queue() periodically from main thread timer
    """

    def init(self):
        self = objc.super(DictationOverlay, self).init()
        if self is None:
            return None

        self.window = None
        self.status_label = None
        self.text_view = None
        self.recording_indicator = None
        self._pending_actions = queue.Queue()

        self._create_window()
        return self

    def _create_window(self):
        """Create the overlay window (must be called on main thread)."""
        screen = NSScreen.mainScreen()
        screen_frame = screen.frame()

        width = 400
        height = 120
        x = (screen_frame.size.width - width) / 2
        y = 100

        frame = NSMakeRect(x, y, width, height)

        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless,
            NSBackingStoreBuffered,
            False
        )

        self.window.setLevel_(kCGFloatingWindowLevel)
        self.window.setOpaque_(False)
        self.window.setBackgroundColor_(NSColor.clearColor())
        self.window.setHasShadow_(True)
        self.window.setIgnoresMouseEvents_(True)

        content_view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
        content_view.setWantsLayer_(True)
        content_view.layer().setBackgroundColor_(TokyoNight.BG.CGColor())
        content_view.layer().setCornerRadius_(12)

        self.recording_indicator = RecordingIndicator.alloc().initWithFrame_(
            NSMakeRect(15, height - 30, 16, 16)
        )
        content_view.addSubview_(self.recording_indicator)

        self.status_label = NSTextField.alloc().initWithFrame_(
            NSMakeRect(40, height - 35, width - 55, 24)
        )
        self.status_label.setStringValue_("Ready")
        self.status_label.setTextColor_(TokyoNight.FG)
        self.status_label.setFont_(NSFont.systemFontOfSize_(14))
        self.status_label.setBezeled_(False)
        self.status_label.setDrawsBackground_(False)
        self.status_label.setEditable_(False)
        self.status_label.setSelectable_(False)
        content_view.addSubview_(self.status_label)

        self.text_view = NSTextField.alloc().initWithFrame_(
            NSMakeRect(15, 15, width - 30, height - 55)
        )
        self.text_view.setStringValue_("")
        self.text_view.setTextColor_(TokyoNight.CYAN)
        self.text_view.setFont_(NSFont.monospacedSystemFontOfSize_weight_(12, 0.0))
        self.text_view.setBezeled_(False)
        self.text_view.setDrawsBackground_(False)
        self.text_view.setEditable_(False)
        self.text_view.setSelectable_(False)
        self.text_view.setLineBreakMode_(NSLineBreakByWordWrapping)
        content_view.addSubview_(self.text_view)

        self.window.setContentView_(content_view)

    # === Thread-safe scheduling methods ===
    # These can be called from any thread

    @objc.python_method
    def schedule_show_recording(self):
        """Schedule show_recording to run on main thread."""
        self._pending_actions.put(("show_recording", None))

    @objc.python_method
    def schedule_show_processing(self):
        """Schedule show_processing to run on main thread."""
        self._pending_actions.put(("show_processing", None))

    @objc.python_method
    def schedule_show_result(self, text, is_llm=False):
        """Schedule show_result to run on main thread."""
        self._pending_actions.put(("show_result", (text, is_llm)))

    @objc.python_method
    def schedule_show_error(self, message):
        """Schedule show_error to run on main thread."""
        self._pending_actions.put(("show_error", message))

    @objc.python_method
    def schedule_hide(self):
        """Schedule hide to run on main thread."""
        self._pending_actions.put(("hide", None))

    @objc.python_method
    def schedule_update_position(self):
        """Schedule update_position to run on main thread."""
        self._pending_actions.put(("update_position", None))

    def processQueue_(self, timer):
        """Process pending actions from the queue (called by timer on main thread)."""
        while True:
            try:
                action, args = self._pending_actions.get_nowait()
                if action == "show_recording":
                    self._do_show_recording()
                elif action == "show_processing":
                    self._do_show_processing()
                elif action == "show_result":
                    self._do_show_result(args[0], args[1])
                elif action == "show_error":
                    self._do_show_error(args)
                elif action == "hide":
                    self._do_hide()
                elif action == "update_position":
                    self._do_update_position()
            except queue.Empty:
                break

    # === Main thread only methods ===

    def _get_mouse_position(self):
        loc = NSEvent.mouseLocation()
        return (loc.x, loc.y)

    def _position_at_cursor(self):
        mouse_x, mouse_y = self._get_mouse_position()
        screen = NSScreen.mainScreen()
        screen_frame = screen.frame()
        window_frame = self.window.frame()
        width = window_frame.size.width
        height = window_frame.size.height

        offset_x = 20
        offset_y = 30
        new_x = mouse_x + offset_x
        new_y = mouse_y - height - offset_y

        if new_x + width > screen_frame.size.width:
            new_x = mouse_x - width - offset_x
        if new_y < 0:
            new_y = mouse_y + offset_y

        self.window.setFrameOrigin_((new_x, new_y))

    def _do_show_recording(self):
        self.status_label.setStringValue_("Recording...")
        self.status_label.setTextColor_(TokyoNight.RED)
        self.text_view.setStringValue_("")
        self.recording_indicator.setRecording_(True)
        self._position_at_cursor()
        self.window.orderFront_(None)

    def _do_show_processing(self):
        self.status_label.setStringValue_("Processing...")
        self.status_label.setTextColor_(TokyoNight.YELLOW)
        self.recording_indicator.setRecording_(False)

    def _do_show_result(self, text, is_llm):
        if is_llm:
            self.status_label.setStringValue_("LLM Response")
            self.status_label.setTextColor_(TokyoNight.MAGENTA)
        else:
            self.status_label.setStringValue_("Transcribed")
            self.status_label.setTextColor_(TokyoNight.GREEN)
        self.recording_indicator.setRecording_(False)
        display_text = text[:200] + "..." if len(text) > 200 else text
        self.text_view.setStringValue_(display_text)

    def _do_show_error(self, message):
        self.status_label.setStringValue_("Error")
        self.status_label.setTextColor_(TokyoNight.RED)
        self.text_view.setStringValue_(message)
        self.recording_indicator.setRecording_(False)

    def _do_hide(self):
        self.window.orderOut_(None)

    def _do_update_position(self):
        if self.window.isVisible():
            self._position_at_cursor()

    # === Convenience methods (main thread only) ===

    def show_recording(self):
        """Show recording state. MAIN THREAD ONLY."""
        self._do_show_recording()

    def show_processing(self):
        """Show processing state. MAIN THREAD ONLY."""
        self._do_show_processing()

    def show_result(self, text, is_llm=False):
        """Show result. MAIN THREAD ONLY."""
        self._do_show_result(text, is_llm)

    def show_error(self, message):
        """Show error. MAIN THREAD ONLY."""
        self._do_show_error(message)

    def hide(self):
        """Hide overlay. MAIN THREAD ONLY."""
        self._do_hide()

    def update_position(self):
        """Update position. MAIN THREAD ONLY."""
        self._do_update_position()


def test_overlay():
    """Test the overlay window."""
    print("=" * 50)
    print("Testing overlay window")
    print("=" * 50)
    print()

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    print("Creating overlay...")
    overlay = DictationOverlay.alloc().init()
    print("Overlay created!")

    # Set up timer to process queue (simulates what the main app would do)
    timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
        0.05,  # 50ms interval
        overlay,
        objc.selector(overlay.processQueue_, signature=b'v@:@'),
        None,
        True
    )

    def demo_flow():
        """Run demo from background thread using schedule_* methods."""
        print(f"[Background thread] Starting demo...")
        time.sleep(0.5)

        print("[Background thread] Scheduling show_recording...")
        overlay.schedule_show_recording()
        time.sleep(2)

        print("[Background thread] Scheduling show_processing...")
        overlay.schedule_show_processing()
        time.sleep(1)

        print("[Background thread] Scheduling show_result...")
        overlay.schedule_show_result("Hello! This is a test transcription.", False)
        time.sleep(2)

        print("[Background thread] Scheduling show_error...")
        overlay.schedule_show_error("Test error message")
        time.sleep(2)

        print("[Background thread] Scheduling hide...")
        overlay.schedule_hide()
        time.sleep(0.5)

        print()
        print("=" * 50)
        print("SUCCESS!")
        print("=" * 50)

        # Quit app
        NSApplication.sharedApplication().performSelectorOnMainThread_withObject_waitUntilDone_(
            objc.selector(NSApplication.sharedApplication().terminate_, signature=b'v@:@'),
            None,
            False
        )

    thread = threading.Thread(target=demo_flow, daemon=True)
    thread.start()

    print("Running app...")
    app.run()


if __name__ == "__main__":
    test_overlay()
