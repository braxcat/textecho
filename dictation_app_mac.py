#!/usr/bin/env python3
"""
Dictation-Mac: Menu bar application for macOS.

Main entry point that coordinates:
- Input monitoring (mouse/keyboard triggers)
- Audio recording
- Transcription via MLX Whisper daemon
- Text injection into active app

Usage:
    python3 dictation_app_mac.py
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path
from typing import Optional

import AppKit
import numpy as np
import objc
import pyaudio
from Foundation import NSObject, NSTimer
from AppKit import (
    NSApplication,
    NSStatusBar,
    NSMenu,
    NSMenuItem,
    NSImage,
    NSVariableStatusItemLength,
    NSApplicationActivationPolicyAccessory,
)

from input_monitor_mac import (
    InputMonitor,
    InputEvent,
    ModifierState,
    MOUSE_BUTTON_MIDDLE,
    MOUSE_BUTTON_BACK,
    MOUSE_BUTTON_FORWARD,
)
from text_injector_mac import TextInjector
# from overlay_mac import DictationOverlay  # TODO: fix overlay crashes


# Default configuration
DEFAULT_CONFIG = {
    "trigger_button": MOUSE_BUTTON_MIDDLE,  # 2=middle, 3=back, 4=forward
    "silence_duration": 2.5,
    "transcription_socket": "/tmp/dictation_transcription.sock",
    "llm_socket": "/tmp/dictation_llm.sock",
    "llm_enabled": False,
}

CONFIG_PATH = Path.home() / ".dictation_config"


class DictationApp(NSObject):
    """Main menu bar application."""

    def init(self):
        self = objc.super(DictationApp, self).init()
        if self is None:
            return None

        # Load configuration
        self.config = self._load_config()

        # State
        self.is_recording = False
        self.is_processing = False
        self.is_llm_mode = False
        self.audio_file: Optional[str] = None
        self.audio_frames = []
        self.recording_thread: Optional[threading.Thread] = None
        self.stop_recording_flag = threading.Event()

        # PyAudio setup
        self.pyaudio = pyaudio.PyAudio()
        self.sample_rate = 16000
        self.channels = 1
        self.chunk_size = 1024

        # Components
        self.input_monitor: Optional[InputMonitor] = None
        self.text_injector = TextInjector()
        # self._overlay = None  # TODO: fix overlay

        # Clipboard registers (for LLM context)
        self.registers = {}

        # Setup menu bar
        self._setup_status_item()
        self._setup_menu()

        # Delay input monitor start until after app run loop begins
        # This avoids conflicts between CGEventTap and NSApplication
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, objc.selector(self.delayedStart_, signature=b'v@:@'), None, False
        )

        return self

    def delayedStart_(self, timer):
        """Start input monitoring after app is fully running."""
        self._start_input_monitor()

    def _load_config(self) -> dict:
        """Load configuration from file."""
        config = DEFAULT_CONFIG.copy()
        if CONFIG_PATH.exists():
            try:
                with open(CONFIG_PATH) as f:
                    user_config = json.load(f)
                    config.update(user_config)
            except (json.JSONDecodeError, IOError) as e:
                print(f"Warning: Could not load config: {e}")
        return config

    def _save_config(self):
        """Save configuration to file."""
        try:
            with open(CONFIG_PATH, 'w') as f:
                json.dump(self.config, f, indent=2)
        except IOError as e:
            print(f"Warning: Could not save config: {e}")

    def _setup_status_item(self):
        """Create the menu bar status item."""
        self.status_bar = NSStatusBar.systemStatusBar()
        self.status_item = self.status_bar.statusItemWithLength_(
            NSVariableStatusItemLength
        )

        # Set initial icon (mic symbol using SF Symbols or text fallback)
        self._set_status_icon("idle")

        self.status_item.setHighlightMode_(True)

    def _set_status_icon(self, state: str):
        """Set the status bar icon based on state."""
        # Use text/emoji as fallback (SF Symbols require more setup)
        icons = {
            "idle": "🎤",
            "recording": "🔴",
            "processing": "⏳",
            "error": "⚠️",
        }
        title = icons.get(state, "🎤")
        self.status_item.setTitle_(title)

    def _setup_menu(self):
        """Create the dropdown menu."""
        self.menu = NSMenu.alloc().init()

        # Status indicator (disabled item showing current state)
        self.status_menu_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Ready", None, ""
        )
        self.status_menu_item.setEnabled_(False)
        self.menu.addItem_(self.status_menu_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Daemon controls
        start_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Start Daemons", "startDaemons:", ""
        )
        start_item.setTarget_(self)
        self.menu.addItem_(start_item)

        stop_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Stop Daemons", "stopDaemons:", ""
        )
        stop_item.setTarget_(self)
        self.menu.addItem_(stop_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Settings
        settings_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Settings...", "showSettings:", ","
        )
        settings_item.setTarget_(self)
        self.menu.addItem_(settings_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Quit
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "quitApp:", "q"
        )
        quit_item.setTarget_(self)
        self.menu.addItem_(quit_item)

        self.status_item.setMenu_(self.menu)

    def _start_input_monitor(self):
        """Start global input monitoring."""
        trigger_button = self.config.get("trigger_button", MOUSE_BUTTON_MIDDLE)

        self.input_monitor = InputMonitor(
            callback=self._handle_input_event,
            trigger_button=trigger_button
        )
        self.input_monitor.start()

    def _handle_input_event(self, event: InputEvent, modifiers: ModifierState, mouse_pos: tuple):
        """Handle input events from the monitor."""

        # Update overlay position while recording
        # if self.is_recording and self.overlay:
        #     self.overlay.update_position()

        if event == InputEvent.TRIGGER_BUTTON_DOWN:
            if modifiers.ctrl:
                # Ctrl + trigger = LLM mode
                self._start_recording(llm_mode=True)
            else:
                # Just trigger = transcription mode
                self._start_recording(llm_mode=False)

        elif event == InputEvent.TRIGGER_BUTTON_UP:
            self._stop_recording()

        elif event == InputEvent.KEY_ESCAPE:
            self._cancel_recording()

        elif event == InputEvent.LEFT_CLICK:
            # If we have pending text, paste it
            pass  # TODO: implement for overlay click-to-paste

        elif event == InputEvent.RIGHT_CLICK:
            # Cancel pending action
            pass  # TODO: implement for overlay right-click-to-cancel

        # Register hotkeys
        elif event == InputEvent.HOTKEY_REGISTER_1:
            self._capture_register(1)
        elif event == InputEvent.HOTKEY_REGISTER_2:
            self._capture_register(2)
        elif event == InputEvent.HOTKEY_REGISTER_3:
            self._capture_register(3)
        elif event == InputEvent.HOTKEY_REGISTER_4:
            self._capture_register(4)
        elif event == InputEvent.HOTKEY_REGISTER_5:
            self._capture_register(5)
        elif event == InputEvent.HOTKEY_REGISTER_6:
            self._capture_register(6)
        elif event == InputEvent.HOTKEY_REGISTER_7:
            self._capture_register(7)
        elif event == InputEvent.HOTKEY_REGISTER_8:
            self._capture_register(8)
        elif event == InputEvent.HOTKEY_REGISTER_9:
            self._capture_register(9)
        elif event == InputEvent.HOTKEY_CLEAR_REGISTERS:
            self._clear_registers()
        elif event == InputEvent.HOTKEY_SETTINGS:
            self.showSettings_(None)

    def _capture_register(self, num: int):
        """Capture clipboard content to a register."""
        content = self.text_injector.get_clipboard()
        if content:
            self.registers[num] = content
            print(f"Register {num} set: {content[:50]}...")

    def _clear_registers(self):
        """Clear all registers."""
        self.registers.clear()
        print("All registers cleared")

    def _start_recording(self, llm_mode: bool = False):
        """Start audio recording."""
        if self.is_recording:
            return

        self.is_recording = True
        self.is_llm_mode = llm_mode
        self._set_status_icon("recording")
        self.status_menu_item.setTitle_("Recording...")

        # Reset state
        self.audio_frames = []
        self.stop_recording_flag.clear()

        # TODO: Show overlay
        # self._run_on_main_thread(lambda: self._get_overlay().show_recording())

        # Start recording in background thread
        self.recording_thread = threading.Thread(target=self._record_audio, daemon=True)
        self.recording_thread.start()
        print("Recording started...")

    def _record_audio(self):
        """Record audio in background thread using PyAudio."""
        try:
            stream = self.pyaudio.open(
                format=pyaudio.paInt16,
                channels=self.channels,
                rate=self.sample_rate,
                input=True,
                frames_per_buffer=self.chunk_size
            )

            while not self.stop_recording_flag.is_set():
                data = stream.read(self.chunk_size, exception_on_overflow=False)
                self.audio_frames.append(data)

            stream.stop_stream()
            stream.close()

        except Exception as e:
            print(f"Recording error: {e}")

    def _stop_recording(self):
        """Stop recording and process audio."""
        if not self.is_recording:
            return

        self.is_recording = False
        self._set_status_icon("processing")
        self.status_menu_item.setTitle_("Processing...")

        # Signal recording thread to stop
        self.stop_recording_flag.set()

        # Wait for recording thread to finish
        if self.recording_thread:
            self.recording_thread.join(timeout=1.0)
            self.recording_thread = None

        # Save audio to temp file
        if self.audio_frames:
            self.audio_file = tempfile.mktemp(suffix=".wav")
            self._save_audio_to_file(self.audio_file)
            print(f"Recording stopped, saved to {self.audio_file}")

            # TODO: Show processing state
            # self._run_on_main_thread(lambda: self._get_overlay().show_processing())

            # Process in background thread
            threading.Thread(target=self._process_audio, daemon=True).start()
        else:
            print("No audio recorded")
            # self._run_on_main_thread(lambda: self._get_overlay().hide())
            self._reset_state()

    def _save_audio_to_file(self, filepath: str):
        """Save recorded audio frames to WAV file."""
        with wave.open(filepath, 'wb') as wf:
            wf.setnchannels(self.channels)
            wf.setsampwidth(self.pyaudio.get_sample_size(pyaudio.paInt16))
            wf.setframerate(self.sample_rate)
            wf.writeframes(b''.join(self.audio_frames))

    def _cancel_recording(self):
        """Cancel current recording."""
        # Signal recording thread to stop
        self.stop_recording_flag.set()

        if self.recording_thread:
            self.recording_thread.join(timeout=1.0)
            self.recording_thread = None

        # Clear audio frames without saving
        self.audio_frames = []

        if self.audio_file and os.path.exists(self.audio_file):
            os.remove(self.audio_file)

        # self._run_on_main_thread(lambda: self._get_overlay().hide())
        self._reset_state()
        print("Recording cancelled")

    def _reset_state(self):
        """Reset to idle state."""
        self.is_recording = False
        self.is_processing = False
        self.is_llm_mode = False
        self.audio_file = None
        self.audio_frames = []
        self._set_status_icon("idle")
        self.status_menu_item.setTitle_("Ready")

    def _process_audio(self):
        """Process recorded audio (runs in background thread)."""
        if not self.audio_file or not os.path.exists(self.audio_file):
            self._reset_state()
            return

        try:
            # Send to transcription daemon
            text = self._transcribe_audio(self.audio_file)

            if text:
                if self.is_llm_mode and self.config.get("llm_enabled"):
                    # Send to LLM
                    response = self._query_llm(text)
                    if response:
                        self._inject_text(response)
                else:
                    # Direct transcription
                    self._inject_text(text)
            else:
                print("No transcription result")

        except Exception as e:
            print(f"Error processing audio: {e}")
            self._set_status_icon("error")

        finally:
            # Clean up audio file
            if self.audio_file and os.path.exists(self.audio_file):
                os.remove(self.audio_file)
            self._reset_state()

    def _transcribe_audio(self, audio_path: str) -> Optional[str]:
        """Send audio to transcription daemon."""
        socket_path = self.config.get("transcription_socket", "/tmp/dictation_transcription.sock")

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(30)  # 30 second timeout for transcription
            sock.connect(socket_path)

            # Send request (daemon expects "command" and "audio_file")
            request = {"command": "transcribe", "audio_file": audio_path}
            sock.sendall(json.dumps(request).encode() + b'\n')

            # Read response
            response = b''
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
                if b'\n' in response:
                    break

            sock.close()

            if not response.strip():
                print("Empty response from daemon")
                return None

            result = json.loads(response.decode().strip())

            if result.get("success"):
                return result.get("transcription", "").strip()
            else:
                print(f"Transcription failed: {result.get('error')}")
                return None

        except socket.timeout:
            print("Transcription timeout")
            return None
        except (socket.error, json.JSONDecodeError) as e:
            print(f"Transcription error: {e}")
            return None

    def _query_llm(self, prompt: str) -> Optional[str]:
        """Send prompt to LLM daemon with context."""
        socket_path = self.config.get("llm_socket", "/tmp/dictation_llm.sock")

        # Build context from registers and clipboard
        context_parts = []
        for num in sorted(self.registers.keys()):
            context_parts.append(f"[Register {num}]:\n{self.registers[num]}")

        clipboard = self.text_injector.get_clipboard()
        if clipboard:
            context_parts.append(f"[Clipboard]:\n{clipboard}")

        context = "\n\n".join(context_parts) if context_parts else ""

        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)

            # Send request
            request = {
                "prompt": prompt,
                "context": context
            }
            sock.sendall(json.dumps(request).encode() + b'\n')

            # Read response (may be streamed)
            response = b''
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
                if b'\n' in response:
                    break

            sock.close()

            result = json.loads(response.decode().strip())
            return result.get("text", "").strip()

        except (socket.error, json.JSONDecodeError) as e:
            print(f"LLM error: {e}")
            return None

    def _inject_text(self, text: str):
        """Inject text into active application."""
        # Small delay to ensure focus is on target app
        time.sleep(0.1)
        success = self.text_injector.inject_text(text)
        if success:
            print(f"Injected: {text[:50]}...")
        else:
            print("Injection failed")

    # Menu actions
    @objc.python_method
    def startDaemons_(self, sender):
        """Start transcription/LLM daemons."""
        script_dir = Path(__file__).parent
        daemon_script = script_dir / "daemon_control.sh"
        if daemon_script.exists():
            subprocess.run([str(daemon_script), "start"])
        else:
            print("daemon_control.sh not found")

    @objc.python_method
    def stopDaemons_(self, sender):
        """Stop transcription/LLM daemons."""
        script_dir = Path(__file__).parent
        daemon_script = script_dir / "daemon_control.sh"
        if daemon_script.exists():
            subprocess.run([str(daemon_script), "stop"])
        else:
            print("daemon_control.sh not found")

    @objc.python_method
    def showSettings_(self, sender):
        """Show settings dialog."""
        # TODO: Implement settings UI
        print("Settings not yet implemented")
        # For now, just print current config
        print(f"Current config: {self.config}")

    @objc.python_method
    def quitApp_(self, sender):
        """Quit the application."""
        if self.input_monitor:
            self.input_monitor.stop()
        NSApplication.sharedApplication().terminate_(None)


def main():
    """Main entry point."""
    print("=" * 50)
    print("Dictation-Mac")
    print("=" * 50)
    print()
    print("Menu bar app starting...")
    print("Trigger: Middle mouse button (hold to record)")
    print("Ctrl + Trigger: LLM mode")
    print("Cmd+Option+1-9: Save to register")
    print("Cmd+Option+0: Clear registers")
    print("ESC: Cancel recording")
    print()

    # Create application
    app = NSApplication.sharedApplication()

    # Set as accessory app (no dock icon)
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    # Create our delegate
    delegate = DictationApp.alloc().init()
    app.setDelegate_(delegate)

    print("Running... (Cmd+Q or menu to quit)")
    print()

    # Run the app
    app.run()


if __name__ == "__main__":
    main()
