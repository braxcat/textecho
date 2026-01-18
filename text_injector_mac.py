#!/usr/bin/env python3
"""
macOS text injection using Accessibility API with clipboard fallback.

Injects text into the currently focused application/text field.
Requires Accessibility permissions in System Preferences > Privacy & Security.

Methods (in order of preference):
1. Direct AXValue insertion (fastest, works in most native apps)
2. Clipboard + Cmd+V paste (universal fallback)
"""

import time
from typing import Optional, Tuple

import AppKit
import Quartz
from ApplicationServices import (
    AXUIElementCreateSystemWide,
    AXUIElementCopyAttributeValue,
    AXUIElementSetAttributeValue,
    AXUIElementCopyElementAtPosition,
    AXIsProcessTrusted,
    kAXFocusedApplicationAttribute,
    kAXFocusedUIElementAttribute,
    kAXValueAttribute,
    kAXSelectedTextRangeAttribute,
    kAXRoleAttribute,
)
from CoreFoundation import CFRange


class TextInjector:
    """
    Injects text into the currently focused text field on macOS.

    Usage:
        injector = TextInjector()

        # Check permissions first
        if not injector.check_accessibility_permission():
            print("Please grant Accessibility permissions")
            injector.request_accessibility_permission()
            return

        # Inject text
        success = injector.inject_text("Hello, world!")
    """

    def __init__(self, use_clipboard_fallback: bool = True):
        """
        Initialize the text injector.

        Args:
            use_clipboard_fallback: If True, fall back to clipboard+paste when
                                   direct injection fails (default: True)
        """
        self.use_clipboard_fallback = use_clipboard_fallback
        self._system_wide = AXUIElementCreateSystemWide()

    def check_accessibility_permission(self) -> bool:
        """Check if the app has Accessibility permissions."""
        return AXIsProcessTrusted()

    def request_accessibility_permission(self) -> None:
        """
        Prompt the user to grant Accessibility permissions.
        Opens System Preferences to the right pane.
        """
        # Open System Preferences to Accessibility pane
        script = '''
        tell application "System Preferences"
            activate
            set securityPane to pane id "com.apple.preference.security"
            tell securityPane to reveal anchor "Privacy_Accessibility"
        end tell
        '''
        import subprocess
        subprocess.run(['osascript', '-e', script], capture_output=True)

    def _get_focused_element(self) -> Tuple[Optional[object], Optional[str]]:
        """
        Get the currently focused UI element.

        Returns:
            Tuple of (AXUIElement, role) or (None, None) if not found
        """
        # Get focused application
        err, focused_app = AXUIElementCopyAttributeValue(
            self._system_wide,
            kAXFocusedApplicationAttribute,
            None
        )
        if err != 0 or focused_app is None:
            return None, None

        # Get focused element within the application
        err, focused_element = AXUIElementCopyAttributeValue(
            focused_app,
            kAXFocusedUIElementAttribute,
            None
        )
        if err != 0 or focused_element is None:
            return None, None

        # Get the role of the element
        err, role = AXUIElementCopyAttributeValue(
            focused_element,
            kAXRoleAttribute,
            None
        )
        role_str = str(role) if role else None

        return focused_element, role_str

    def _inject_via_accessibility(self, text: str) -> bool:
        """
        Try to inject text directly via Accessibility API.

        Args:
            text: The text to inject

        Returns:
            True if successful, False otherwise
        """
        element, role = self._get_focused_element()
        if element is None:
            return False

        # Check if this is a text-input element
        text_roles = ['AXTextField', 'AXTextArea', 'AXComboBox', 'AXSearchField']
        if role not in text_roles:
            # Not a recognized text field, but still try
            pass

        # Try to get current value and selection
        err, current_value = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute,
            None
        )

        # Try to set the value directly (append or replace based on selection)
        if err == 0 and current_value is not None:
            # Get selected text range to insert at cursor position
            err, selection = AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute,
                None
            )

            if err == 0 and selection is not None:
                # Insert at cursor position
                try:
                    loc = selection.location
                    length = selection.length
                    current_str = str(current_value)
                    new_value = current_str[:loc] + text + current_str[loc + length:]

                    err = AXUIElementSetAttributeValue(
                        element,
                        kAXValueAttribute,
                        new_value
                    )
                    if err == 0:
                        return True
                except (AttributeError, TypeError):
                    pass

            # Fall back to appending
            try:
                new_value = str(current_value) + text
                err = AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute,
                    new_value
                )
                if err == 0:
                    return True
            except (AttributeError, TypeError):
                pass

        # Try setting value directly (for empty fields)
        err = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute,
            text
        )
        return err == 0

    def _inject_via_clipboard(self, text: str) -> bool:
        """
        Inject text via clipboard and Cmd+V paste.

        Args:
            text: The text to inject

        Returns:
            True if paste was triggered (doesn't guarantee success)
        """
        # Save current clipboard content
        pasteboard = AppKit.NSPasteboard.generalPasteboard()
        old_contents = pasteboard.stringForType_(AppKit.NSPasteboardTypeString)

        # Set new clipboard content
        pasteboard.clearContents()
        pasteboard.setString_forType_(text, AppKit.NSPasteboardTypeString)

        # Small delay to ensure clipboard is ready
        time.sleep(0.05)

        # Simulate Cmd+V
        self._simulate_paste()

        # Small delay before potentially restoring clipboard
        time.sleep(0.1)

        # Optionally restore old clipboard (disabled by default as it can interfere)
        # if old_contents:
        #     pasteboard.clearContents()
        #     pasteboard.setString_forType_(old_contents, AppKit.NSPasteboardTypeString)

        return True

    def _simulate_paste(self) -> None:
        """Simulate Cmd+V keystroke."""
        # Key code for 'V' is 9
        v_keycode = 9

        # Create key down event with Cmd modifier
        event_down = Quartz.CGEventCreateKeyboardEvent(None, v_keycode, True)
        Quartz.CGEventSetFlags(event_down, Quartz.kCGEventFlagMaskCommand)

        # Create key up event with Cmd modifier
        event_up = Quartz.CGEventCreateKeyboardEvent(None, v_keycode, False)
        Quartz.CGEventSetFlags(event_up, Quartz.kCGEventFlagMaskCommand)

        # Post the events
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_down)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event_up)

    def inject_text(self, text: str, method: str = "clipboard") -> bool:
        """
        Inject text into the currently focused text field.

        Args:
            text: The text to inject
            method: Injection method - "clipboard" (default, most reliable),
                   "accessibility" (direct API, works in some native apps),
                   "auto" (try accessibility first, fall back to clipboard)

        Returns:
            True if injection succeeded (or was attempted via clipboard)
        """
        if not text:
            return True

        if method == "clipboard":
            return self._inject_via_clipboard(text)
        elif method == "accessibility":
            return self._inject_via_accessibility(text)
        elif method == "auto":
            # Try accessibility first, fall back to clipboard
            if self._inject_via_accessibility(text):
                return True
            if self.use_clipboard_fallback:
                return self._inject_via_clipboard(text)
            return False
        else:
            # Default to clipboard
            return self._inject_via_clipboard(text)

    def set_clipboard(self, text: str) -> None:
        """
        Set the clipboard content without pasting.

        Useful when you want to let the user paste manually.

        Args:
            text: The text to put on the clipboard
        """
        pasteboard = AppKit.NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        pasteboard.setString_forType_(text, AppKit.NSPasteboardTypeString)

    def get_clipboard(self) -> Optional[str]:
        """
        Get the current clipboard content.

        Returns:
            The clipboard text, or None if empty/not text
        """
        pasteboard = AppKit.NSPasteboard.generalPasteboard()
        return pasteboard.stringForType_(AppKit.NSPasteboardTypeString)


def test_text_injector():
    """Interactive test for text injection."""
    print("=" * 60)
    print("Text Injector Test")
    print("=" * 60)
    print()

    injector = TextInjector()

    # Check permissions
    if not injector.check_accessibility_permission():
        print("WARNING: Accessibility permissions not granted!")
        print("Some features may not work.")
        print()
        response = input("Open System Preferences to grant access? [y/N]: ")
        if response.lower() == 'y':
            injector.request_accessibility_permission()
            print("Please grant access, then run this test again.")
            return
    else:
        print("Accessibility permissions: OK")

    print()
    print("Instructions:")
    print("1. Press Enter here to start 3-second countdown")
    print("2. Quickly click into a text field in another app")
    print("3. Text will be injected after countdown")
    print()

    test_text = "Hello from dictation-mac! "

    while True:
        input(f"Press Enter to start countdown (Ctrl+C to quit)")

        for i in range(3, 0, -1):
            print(f"  {i}...")
            time.sleep(1)

        print("Injecting text NOW!")
        success = injector.inject_text(test_text, method="clipboard")

        if success:
            print("Text pasted (check the target field)")
        else:
            print("Injection failed")

        print()


if __name__ == "__main__":
    test_text_injector()
