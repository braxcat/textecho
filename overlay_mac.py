#!/usr/bin/env python3
"""
macOS overlay window for dictation feedback.

Shows recording status, transcription progress, and LLM responses.
Uses AppKit for native macOS window with transparency.
"""

import threading
import time
from typing import Optional

import AppKit
import objc
from Foundation import NSObject, NSMakeRect
from AppKit import NSEvent
import AppKit
from AppKit import (
    NSWindow,
    NSView,
    NSColor,
    NSFont,
    NSTextField,
    NSBezierPath,
    NSScreen,
    NSApplication,
    NSApplicationActivationPolicyAccessory,
)

# Window constants
NSWindowStyleMaskBorderless = 0
NSBackingStoreBuffered = 2
kCGFloatingWindowLevel = 3  # Floating window level


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
    """Recording indicator dot (static, no animation to avoid threading issues)."""

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

        # Draw solid red circle
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

    def startPulsing(self):
        """Show the recording indicator."""
        self.is_recording = True
        self.setNeedsDisplay_(True)

    def stopPulsing(self):
        """Hide the recording indicator."""
        self.is_recording = False
        self.setNeedsDisplay_(True)


class DictationOverlay(NSObject):
    """
    Overlay window for dictation feedback.

    Shows:
    - Recording indicator (pulsing red dot)
    - Status text (Recording... / Processing... / etc.)
    - Transcription result or LLM response
    """

    def init(self):
        self = objc.super(DictationOverlay, self).init()
        if self is None:
            return None

        self.window = None
        self.status_label = None
        self.text_view = None
        self.recording_indicator = None

        self._create_window()
        return self

    def _create_window(self):
        """Create the overlay window."""
        # Get screen size for positioning
        screen = NSScreen.mainScreen()
        screen_frame = screen.frame()

        # Window size and position (bottom center of screen)
        width = 400
        height = 120
        x = (screen_frame.size.width - width) / 2
        y = 100  # 100px from bottom

        frame = NSMakeRect(x, y, width, height)

        # Create borderless, transparent window
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
        self.window.setIgnoresMouseEvents_(True)  # Click-through

        # Create content view with rounded corners
        content_view = NSView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
        content_view.setWantsLayer_(True)
        content_view.layer().setBackgroundColor_(TokyoNight.BG.CGColor())
        content_view.layer().setCornerRadius_(12)

        # Recording indicator (top-left)
        self.recording_indicator = RecordingIndicator.alloc().initWithFrame_(
            NSMakeRect(15, height - 30, 16, 16)
        )
        content_view.addSubview_(self.recording_indicator)

        # Status label (next to indicator)
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

        # Text display area
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
        self.text_view.setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
        content_view.addSubview_(self.text_view)

        self.window.setContentView_(content_view)

    def _get_mouse_position(self):
        """Get current mouse position."""
        # NSEvent.mouseLocation() returns in screen coordinates (bottom-left origin)
        loc = NSEvent.mouseLocation()
        return (loc.x, loc.y)

    def _position_at_cursor(self):
        """Position the overlay window near the cursor."""
        mouse_x, mouse_y = self._get_mouse_position()

        # Get screen info
        screen = NSScreen.mainScreen()
        screen_frame = screen.frame()

        # Get window size
        window_frame = self.window.frame()
        width = window_frame.size.width
        height = window_frame.size.height

        # Position below and to the right of cursor with offset
        # NSEvent.mouseLocation() is already in AppKit coords (bottom-left origin)
        offset_x = 20
        offset_y = 30

        new_x = mouse_x + offset_x
        new_y = mouse_y - height - offset_y

        # Keep on screen
        if new_x + width > screen_frame.size.width:
            new_x = mouse_x - width - offset_x
        if new_y < 0:
            new_y = mouse_y + offset_y

        self.window.setFrameOrigin_((new_x, new_y))

    def show(self):
        """Show the overlay window."""
        self._position_at_cursor()
        self.window.orderFront_(None)

    def hide(self):
        """Hide the overlay window."""
        self.window.orderOut_(None)

    def update_position(self):
        """Update overlay position to follow cursor."""
        if self.window.isVisible():
            self._position_at_cursor()

    def show_recording(self):
        """Show recording state."""
        self.status_label.setStringValue_("Recording...")
        self.status_label.setTextColor_(TokyoNight.RED)
        self.text_view.setStringValue_("")
        self.recording_indicator.startPulsing()
        self.show()

    def show_processing(self):
        """Show processing state."""
        self.status_label.setStringValue_("Processing...")
        self.status_label.setTextColor_(TokyoNight.YELLOW)
        self.recording_indicator.stopPulsing()

    def show_result(self, text: str, is_llm: bool = False):
        """Show transcription/LLM result."""
        if is_llm:
            self.status_label.setStringValue_("LLM Response")
            self.status_label.setTextColor_(TokyoNight.MAGENTA)
        else:
            self.status_label.setStringValue_("Transcribed")
            self.status_label.setTextColor_(TokyoNight.GREEN)

        self.recording_indicator.stopPulsing()

        # Truncate if too long
        display_text = text[:200] + "..." if len(text) > 200 else text
        self.text_view.setStringValue_(display_text)

    def show_error(self, message: str):
        """Show error state."""
        self.status_label.setStringValue_("Error")
        self.status_label.setTextColor_(TokyoNight.RED)
        self.text_view.setStringValue_(message)
        self.recording_indicator.stopPulsing()

    def set_text(self, text: str):
        """Update the text display."""
        display_text = text[:200] + "..." if len(text) > 200 else text
        self.text_view.setStringValue_(display_text)


def test_overlay():
    """Test the overlay window."""
    print("Testing overlay window...")

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    overlay = DictationOverlay.alloc().init()

    # Simulate recording flow
    print("Showing recording state...")
    overlay.show_recording()

    def demo_flow():
        time.sleep(2)

        print("Showing processing state...")
        overlay.show_processing()
        time.sleep(1)

        print("Showing result...")
        overlay.show_result("Hello, this is a test transcription from the overlay window.")
        time.sleep(3)

        print("Hiding overlay...")
        overlay.hide()
        time.sleep(1)

        print("Done!")
        app.terminate_(None)

    threading.Thread(target=demo_flow, daemon=True).start()

    app.run()


if __name__ == "__main__":
    test_overlay()
