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

import logging
import threading
import time
from dataclasses import dataclass
from enum import Enum, auto
from typing import Callable, Optional

from pynput import keyboard, mouse

logger = logging.getLogger(__name__)


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
    HOTKEY_DICTATE_DOWN = auto()  # Ctrl+D pressed (start recording)
    HOTKEY_DICTATE_UP = auto()  # Ctrl+D released (stop recording)
    HOTKEY_DICTATE_LLM_DOWN = auto()  # Ctrl+Shift+D pressed (start LLM recording)
    HOTKEY_DICTATE_LLM_UP = auto()  # Ctrl+Shift+D released (stop LLM recording)


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
        self.mouse_listener: Optional[mouse.Listener] = None
        self.running = False

        # Track trigger button state
        self.trigger_pressed = False

        # Track keyboard dictation state (for hold-to-record)
        self.dictate_key_active = False
        self.dictate_llm_mode = False

    def _emit(self, event: InputEvent):
        """Emit an event to the callback"""
        try:
            self.callback(event, self.modifiers, self.mouse_position)
        except Exception as e:
            print(f"Error in input callback: {e}")

    def _on_key_press(self, key):
        """Handle key press events"""
        # Debug: log all key presses
        try:
            vk = getattr(key, 'vk', None)
            char = getattr(key, 'char', None)
            print(f"DEBUG key_press: key={key}, vk={vk}, char={repr(char)}, ctrl={self.modifiers.ctrl}", flush=True)
        except:
            pass

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

        # Ctrl+D = hold to dictate
        # Ctrl+Shift+D = hold for LLM dictation
        # Virtual key code for 'd' on macOS is 2
        elif self.modifiers.ctrl and not self.modifiers.cmd and not self.modifiers.alt:
            is_d_key = False
            try:
                # Check virtual key code (works even with Ctrl held)
                vk = getattr(key, 'vk', None)
                char = getattr(key, 'char', None)
                print(f"DEBUG Ctrl+key: vk={vk}, char={repr(char)}", flush=True)
                if vk == 2:  # 'd' key on macOS
                    is_d_key = True
                # Also check char in case vk isn't available
                if char and char.lower() == 'd':
                    is_d_key = True
                # Ctrl+D produces '\x04' (EOT character)
                if char == '\x04':
                    is_d_key = True
            except AttributeError:
                pass

            if is_d_key and not self.dictate_key_active:
                self.dictate_key_active = True
                if self.modifiers.shift:
                    self.dictate_llm_mode = True
                    self._emit(InputEvent.HOTKEY_DICTATE_LLM_DOWN)
                else:
                    self.dictate_llm_mode = False
                    self._emit(InputEvent.HOTKEY_DICTATE_DOWN)

    def _on_key_release(self, key):
        """Handle key release events"""
        # Check if D key is released while dictation is active
        if self.dictate_key_active:
            is_d_key = False
            try:
                vk = getattr(key, 'vk', None)
                if vk == 2:  # 'd' key
                    is_d_key = True
                char = getattr(key, 'char', None)
                if char and char.lower() == 'd':
                    is_d_key = True
                if char == '\x04':
                    is_d_key = True
            except AttributeError:
                pass

            # Stop dictation if D is released
            if is_d_key:
                self.dictate_key_active = False
                if self.dictate_llm_mode:
                    self._emit(InputEvent.HOTKEY_DICTATE_LLM_UP)
                else:
                    self._emit(InputEvent.HOTKEY_DICTATE_UP)

        # Update modifier state
        if key == keyboard.Key.cmd or key == keyboard.Key.cmd_r:
            self.modifiers.cmd = False
        elif key == keyboard.Key.ctrl or key == keyboard.Key.ctrl_r:
            # Stop dictation if Ctrl is released while active
            if self.dictate_key_active:
                self.dictate_key_active = False
                if self.dictate_llm_mode:
                    self._emit(InputEvent.HOTKEY_DICTATE_LLM_UP)
                else:
                    self._emit(InputEvent.HOTKEY_DICTATE_UP)
            self.modifiers.ctrl = False
        elif key == keyboard.Key.alt or key == keyboard.Key.alt_r:
            self.modifiers.alt = False
        elif key == keyboard.Key.shift or key == keyboard.Key.shift_r:
            self.modifiers.shift = False

        # Check for escape
        if key == keyboard.Key.esc:
            self._emit(InputEvent.KEY_ESCAPE)

    def _on_mouse_click(self, x, y, button, pressed):
        """Handle pynput mouse click events"""
        self.mouse_position = (int(x), int(y))

        # Map pynput button to our numbering
        # pynput: Button.left, Button.right, Button.middle, Button.x1, Button.x2
        button_map = {
            mouse.Button.left: MOUSE_BUTTON_LEFT,
            mouse.Button.right: MOUSE_BUTTON_RIGHT,
            mouse.Button.middle: MOUSE_BUTTON_MIDDLE,
        }
        # Handle extra buttons (x1=back, x2=forward)
        if hasattr(mouse.Button, 'x1'):
            button_map[mouse.Button.x1] = MOUSE_BUTTON_BACK
        if hasattr(mouse.Button, 'x2'):
            button_map[mouse.Button.x2] = MOUSE_BUTTON_FORWARD

        button_num = button_map.get(button)

        # Debug output
        logger.debug("Mouse click: button=%s, num=%s, pressed=%s, trigger=%s",
                     button, button_num, pressed, self.trigger_button)

        if button_num is None:
            return

        # Handle trigger button
        if button_num == self.trigger_button:
            if pressed:
                self.trigger_pressed = True
                self._emit(InputEvent.TRIGGER_BUTTON_DOWN)
            else:
                self.trigger_pressed = False
                self._emit(InputEvent.TRIGGER_BUTTON_UP)
        # Handle left/right clicks (on release only)
        elif not pressed:
            if button_num == MOUSE_BUTTON_LEFT:
                self._emit(InputEvent.LEFT_CLICK)
            elif button_num == MOUSE_BUTTON_RIGHT:
                self._emit(InputEvent.RIGHT_CLICK)

    def _on_mouse_move(self, x, y):
        """Track mouse position"""
        self.mouse_position = (int(x), int(y))

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

        # Start mouse listener (pynput)
        self.mouse_listener = mouse.Listener(
            on_click=self._on_mouse_click,
            on_move=self._on_mouse_move
        )
        self.mouse_listener.start()

        button_names = {
            MOUSE_BUTTON_LEFT: "Left",
            MOUSE_BUTTON_RIGHT: "Right",
            MOUSE_BUTTON_MIDDLE: "Middle",
            MOUSE_BUTTON_BACK: "Back",
            MOUSE_BUTTON_FORWARD: "Forward",
        }
        btn_name = button_names.get(self.trigger_button, f"Button {self.trigger_button}")
        logger.info("Input monitor started (trigger: %s button)", btn_name)

    def stop(self):
        """Stop listening for input events"""
        self.running = False

        if self.keyboard_listener:
            self.keyboard_listener.stop()
            self.keyboard_listener = None

        if self.mouse_listener:
            self.mouse_listener.stop()
            self.mouse_listener = None

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
    print("  - Hold Ctrl+D (dictation - hold to record, release to transcribe)")
    print("  - Hold Ctrl+Shift+D (LLM dictation)")
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
