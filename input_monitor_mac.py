#!/usr/bin/env python3
"""
macOS input monitor using CGEventTap for mouse and pynput for keyboard.

Replaces Linux evdev-based input handling for macOS.
Requires Accessibility permissions in System Preferences > Privacy & Security.

Mouse button mapping (macOS):
  - Button 0: Left
  - Button 1: Right
  - Button 2: Middle (wheel click)
  - Button 3: Back (side button)
  - Button 4: Forward (side button)
"""

import threading
import time
from dataclasses import dataclass
from enum import Enum, auto
from typing import Callable, Optional

import AppKit
from AppKit import NSEvent
from pynput import keyboard


class InputEvent(Enum):
    """Types of input events we care about"""
    # Mouse events
    TRIGGER_BUTTON_DOWN = auto()  # Configurable trigger button pressed
    TRIGGER_BUTTON_UP = auto()    # Configurable trigger button released
    LEFT_CLICK = auto()
    RIGHT_CLICK = auto()

    # Keyboard events
    KEY_ESCAPE = auto()

    # Hotkey events (combinations)
    HOTKEY_REGISTER_1 = auto()  # Cmd+Option+1
    HOTKEY_REGISTER_2 = auto()
    HOTKEY_REGISTER_3 = auto()
    HOTKEY_REGISTER_4 = auto()
    HOTKEY_REGISTER_5 = auto()
    HOTKEY_REGISTER_6 = auto()
    HOTKEY_REGISTER_7 = auto()
    HOTKEY_REGISTER_8 = auto()
    HOTKEY_REGISTER_9 = auto()
    HOTKEY_CLEAR_REGISTERS = auto()  # Cmd+Option+0
    HOTKEY_SETTINGS = auto()  # Cmd+Option+Space


# Mouse button constants for configuration
MOUSE_BUTTON_LEFT = 0
MOUSE_BUTTON_RIGHT = 1
MOUSE_BUTTON_MIDDLE = 2
MOUSE_BUTTON_BACK = 3
MOUSE_BUTTON_FORWARD = 4


@dataclass
class ModifierState:
    """Track modifier key states"""
    cmd: bool = False      # Command (⌘)
    ctrl: bool = False     # Control (⌃)
    alt: bool = False      # Option (⌥)
    shift: bool = False    # Shift (⇧)


class InputMonitor:
    """
    Monitors keyboard and mouse events globally on macOS.

    Uses CGEventTap for reliable mouse button detection (including side buttons)
    and pynput for keyboard events.

    Usage:
        def handle_event(event, modifiers, mouse_pos):
            if event == InputEvent.TRIGGER_BUTTON_DOWN:
                print("Recording started!")
            elif event == InputEvent.TRIGGER_BUTTON_UP:
                print("Recording stopped!")

        monitor = InputMonitor(callback=handle_event, trigger_button=MOUSE_BUTTON_MIDDLE)
        monitor.start()
        # ... do stuff ...
        monitor.stop()
    """

    def __init__(
        self,
        callback: Callable[[InputEvent, ModifierState, tuple], None],
        trigger_button: int = MOUSE_BUTTON_MIDDLE
    ):
        """
        Initialize the input monitor.

        Args:
            callback: Function called for each relevant input event.
                      Receives (event, modifiers, mouse_position) as arguments.
            trigger_button: Mouse button number to use as trigger (default: middle/2)
                           Use MOUSE_BUTTON_* constants.
        """
        self.callback = callback
        self.trigger_button = trigger_button
        self.modifiers = ModifierState()
        self.mouse_position = (0, 0)

        self.keyboard_listener: Optional[keyboard.Listener] = None
        self._mouse_monitor = None
        self.running = False

        # Track trigger button state
        self.trigger_pressed = False

    def _emit(self, event: InputEvent):
        """Emit an event to the callback"""
        try:
            self.callback(event, self.modifiers, self.mouse_position)
        except Exception as e:
            print(f"Error in input callback: {e}")

    def _on_key_press(self, key):
        """Handle key press events"""
        # Update modifier state
        if key == keyboard.Key.cmd or key == keyboard.Key.cmd_r:
            self.modifiers.cmd = True
        elif key == keyboard.Key.ctrl or key == keyboard.Key.ctrl_r:
            self.modifiers.ctrl = True
        elif key == keyboard.Key.alt or key == keyboard.Key.alt_r:
            self.modifiers.alt = True
        elif key == keyboard.Key.shift or key == keyboard.Key.shift_r:
            self.modifiers.shift = True

        # Check for hotkeys (Cmd+Option+number for registers)
        # On macOS, Cmd+Option modifies the character, so we check virtual key codes
        if self.modifiers.cmd and self.modifiers.alt:
            # Map virtual key codes to numbers (macOS key codes for number row)
            vk_to_num = {
                18: '1', 19: '2', 20: '3', 21: '4', 23: '5',
                22: '6', 26: '7', 28: '8', 25: '9', 29: '0'
            }

            try:
                # Try to get virtual key code
                vk = getattr(key, 'vk', None)
                char = vk_to_num.get(vk) if vk else None

                # Fall back to checking char directly (might work in some cases)
                if not char and hasattr(key, 'char') and key.char:
                    if key.char in '0123456789':
                        char = key.char

                if char == '1':
                    self._emit(InputEvent.HOTKEY_REGISTER_1)
                elif char == '2':
                    self._emit(InputEvent.HOTKEY_REGISTER_2)
                elif char == '3':
                    self._emit(InputEvent.HOTKEY_REGISTER_3)
                elif char == '4':
                    self._emit(InputEvent.HOTKEY_REGISTER_4)
                elif char == '5':
                    self._emit(InputEvent.HOTKEY_REGISTER_5)
                elif char == '6':
                    self._emit(InputEvent.HOTKEY_REGISTER_6)
                elif char == '7':
                    self._emit(InputEvent.HOTKEY_REGISTER_7)
                elif char == '8':
                    self._emit(InputEvent.HOTKEY_REGISTER_8)
                elif char == '9':
                    self._emit(InputEvent.HOTKEY_REGISTER_9)
                elif char == '0':
                    self._emit(InputEvent.HOTKEY_CLEAR_REGISTERS)
                elif key == keyboard.Key.space:
                    self._emit(InputEvent.HOTKEY_SETTINGS)
            except AttributeError:
                pass

    def _on_key_release(self, key):
        """Handle key release events"""
        # Update modifier state
        if key == keyboard.Key.cmd or key == keyboard.Key.cmd_r:
            self.modifiers.cmd = False
        elif key == keyboard.Key.ctrl or key == keyboard.Key.ctrl_r:
            self.modifiers.ctrl = False
        elif key == keyboard.Key.alt or key == keyboard.Key.alt_r:
            self.modifiers.alt = False
        elif key == keyboard.Key.shift or key == keyboard.Key.shift_r:
            self.modifiers.shift = False

        # Check for escape
        if key == keyboard.Key.esc:
            self._emit(InputEvent.KEY_ESCAPE)

    def _handle_mouse_event(self, event):
        """Handle NSEvent mouse events"""
        # Update mouse position
        loc = NSEvent.mouseLocation()
        self.mouse_position = (int(loc.x), int(loc.y))

        event_type = event.type()

        # Handle left/right clicks (on release)
        if event_type == AppKit.NSEventTypeLeftMouseUp:
            self._emit(InputEvent.LEFT_CLICK)
        elif event_type == AppKit.NSEventTypeRightMouseUp:
            self._emit(InputEvent.RIGHT_CLICK)

        # Handle other mouse buttons
        elif event_type == AppKit.NSEventTypeOtherMouseDown:
            button_num = event.buttonNumber()
            if button_num == self.trigger_button:
                self.trigger_pressed = True
                self._emit(InputEvent.TRIGGER_BUTTON_DOWN)

        elif event_type == AppKit.NSEventTypeOtherMouseUp:
            button_num = event.buttonNumber()
            if button_num == self.trigger_button:
                self.trigger_pressed = False
                self._emit(InputEvent.TRIGGER_BUTTON_UP)

    def _setup_mouse_monitor(self):
        """Set up NSEvent global monitor for mouse events"""
        # Event mask for mouse events we care about
        event_mask = (
            AppKit.NSEventMaskLeftMouseUp |
            AppKit.NSEventMaskRightMouseUp |
            AppKit.NSEventMaskOtherMouseDown |
            AppKit.NSEventMaskOtherMouseUp
        )

        # Create global monitor
        self._mouse_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            event_mask,
            self._handle_mouse_event
        )

        if self._mouse_monitor is None:
            print("ERROR: Failed to create mouse event monitor!")
            print("Grant Accessibility permissions in System Preferences.")
            return

        print("Mouse event monitor enabled")

    def start(self):
        """Start listening for input events"""
        if self.running:
            return

        self.running = True

        # Start keyboard listener (pynput)
        self.keyboard_listener = keyboard.Listener(
            on_press=self._on_key_press,
            on_release=self._on_key_release
        )
        self.keyboard_listener.start()

        # Setup mouse listener (NSEvent global monitor)
        self._setup_mouse_monitor()

        button_names = {
            MOUSE_BUTTON_LEFT: "Left",
            MOUSE_BUTTON_RIGHT: "Right",
            MOUSE_BUTTON_MIDDLE: "Middle",
            MOUSE_BUTTON_BACK: "Back",
            MOUSE_BUTTON_FORWARD: "Forward",
        }
        btn_name = button_names.get(self.trigger_button, f"Button {self.trigger_button}")
        print(f"Input monitor started (trigger: {btn_name} button)")

    def stop(self):
        """Stop listening for input events"""
        self.running = False

        if self.keyboard_listener:
            self.keyboard_listener.stop()
            self.keyboard_listener = None

        if self._mouse_monitor:
            NSEvent.removeMonitor_(self._mouse_monitor)
            self._mouse_monitor = None

        print("Input monitor stopped")

    def is_trigger_pressed(self) -> bool:
        """Check if the trigger button is currently pressed"""
        return self.trigger_pressed


def test_input_monitor():
    """Interactive test for the input monitor"""
    print("=" * 60)
    print("Input Monitor Test (CGEventTap + pynput)")
    print("=" * 60)
    print()
    print("Requires Accessibility permissions.")
    print("Grant in: System Preferences > Privacy & Security > Accessibility")
    print()
    print("Trigger button: Middle (wheel click) - configurable")
    print()
    print("Try the following:")
    print("  - Click middle mouse button (trigger)")
    print("  - Press Cmd+Option+1 through 9 (register hotkeys)")
    print("  - Press Cmd+Option+0 (clear registers)")
    print("  - Press Cmd+Option+Space (settings)")
    print("  - Press ESC to quit")
    print()
    print("-" * 60)

    should_quit = threading.Event()

    def handle_event(event: InputEvent, modifiers: ModifierState, mouse_pos: tuple):
        mod_str = ""
        if modifiers.cmd:
            mod_str += "⌘"
        if modifiers.ctrl:
            mod_str += "⌃"
        if modifiers.alt:
            mod_str += "⌥"
        if modifiers.shift:
            mod_str += "⇧"

        print(f"Event: {event.name:30} | Mods: {mod_str:4} | Mouse: {mouse_pos}")

        if event == InputEvent.KEY_ESCAPE:
            print("\nESC pressed - quitting...")
            should_quit.set()

    # Default to middle button, but can be changed
    monitor = InputMonitor(callback=handle_event, trigger_button=MOUSE_BUTTON_MIDDLE)
    monitor.start()

    try:
        while not should_quit.is_set():
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nInterrupted")
    finally:
        monitor.stop()


if __name__ == "__main__":
    test_input_monitor()
