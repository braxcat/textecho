#!/usr/bin/env python3
"""Minimal test to see if basic AppKit window works."""

from AppKit import (
    NSApplication,
    NSWindow,
    NSView,
    NSColor,
    NSApplicationActivationPolicyAccessory,
)
from Foundation import NSMakeRect

NSWindowStyleMaskBorderless = 0
NSBackingStoreBuffered = 2

def test_minimal():
    print("Creating app...")
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    print("Creating window...")
    frame = NSMakeRect(100, 100, 300, 200)
    window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
        frame,
        NSWindowStyleMaskBorderless,
        NSBackingStoreBuffered,
        False
    )

    print("Configuring window...")
    window.setBackgroundColor_(NSColor.redColor())
    window.setOpaque_(True)
    window.setLevel_(3)  # Floating

    print("Showing window...")
    window.orderFront_(None)

    print("Window should be visible now!")
    print("Press Ctrl+C to quit")

    app.run()

if __name__ == "__main__":
    test_minimal()
