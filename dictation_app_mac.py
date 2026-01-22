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
from overlay_swift import SwiftOverlay


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
        self.overlay = SwiftOverlay()
        self.overlay.start()

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

        # Daemon status (will be updated dynamically)
        self.daemon_status_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Daemon: checking...", None, ""
        )
        self.daemon_status_item.setEnabled_(False)
        self.menu.addItem_(self.daemon_status_item)

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

        restart_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Restart Daemons", "restartDaemons:", ""
        )
        restart_item.setTarget_(self)
        self.menu.addItem_(restart_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Install/Uninstall submenu
        install_menu = NSMenu.alloc().init()

        install_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Install Auto-Start", "installDaemons:", ""
        )
        install_item.setTarget_(self)
        install_menu.addItem_(install_item)

        uninstall_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Remove Auto-Start", "uninstallDaemons:", ""
        )
        uninstall_item.setTarget_(self)
        install_menu.addItem_(uninstall_item)

        install_submenu_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Auto-Start Options", None, ""
        )
        install_submenu_item.setSubmenu_(install_menu)
        self.menu.addItem_(install_submenu_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # View logs
        logs_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "View Logs...", "viewLogs:", ""
        )
        logs_item.setTarget_(self)
        self.menu.addItem_(logs_item)

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

        # Update daemon status initially
        self._update_daemon_status()

    def _update_daemon_status(self):
        """Update the daemon status display in menu."""
        socket_path = self.config.get("transcription_socket", "/tmp/dictation_transcription.sock")
        if os.path.exists(socket_path):
            self.daemon_status_item.setTitle_("Daemon: ✓ Running")
        else:
            self.daemon_status_item.setTitle_("Daemon: ✗ Not Running")

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

        # Overlay position tracking is handled by Swift automatically

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

        # Show overlay (queue for main thread)
        if self.overlay:
            self.overlay.show_recording()

        # Start recording in background thread
        self.recording_thread = threading.Thread(target=self._record_audio, daemon=True)
        self.recording_thread.start()
        print("Recording started...")

    def _record_audio(self):
        """Record audio in background thread using PyAudio."""
        stream = None
        try:
            stream = self.pyaudio.open(
                format=pyaudio.paInt16,
                channels=self.channels,
                rate=self.sample_rate,
                input=True,
                frames_per_buffer=self.chunk_size
            )

            # Waveform state (updated in background)
            self._waveform_levels = [0.05] * 40
            self._pending_level = None

            # Start waveform updater thread
            def waveform_updater():
                while not self.stop_recording_flag.is_set():
                    if self._pending_level is not None and self.overlay:
                        level = self._pending_level
                        self._pending_level = None
                        self._waveform_levels.pop(0)
                        self._waveform_levels.append(level)
                        self.overlay.update_waveform(list(self._waveform_levels))
                    time.sleep(0.05)  # 20 updates per second max

            waveform_thread = threading.Thread(target=waveform_updater, daemon=True)
            waveform_thread.start()

            while not self.stop_recording_flag.is_set():
                data = stream.read(self.chunk_size, exception_on_overflow=False)
                self.audio_frames.append(data)

                # Quick level calculation (non-blocking, stored for waveform thread)
                audio_data = np.frombuffer(data, dtype=np.int16)
                rms = np.sqrt(np.mean(audio_data.astype(np.float32) ** 2))
                # More sensitive scaling + boost quiet sounds with sqrt curve
                level = min(rms / 2000, 1.0)  # More sensitive (was 8000)
                level = np.sqrt(level)  # Boost quieter sounds
                self._pending_level = float(level)

        except Exception as e:
            print(f"Recording error: {e}")
        finally:
            if stream:
                try:
                    stream.stop_stream()
                    stream.close()
                except Exception:
                    pass

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

            # Show processing state (queue for main thread)
            if self.overlay:
                self.overlay.show_processing()

            # Process in background thread
            threading.Thread(target=self._process_audio, daemon=True).start()
        else:
            print("No audio recorded")
            if self.overlay:
                self.overlay.hide()
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

        if self.overlay:
            self.overlay.hide()
        self._reset_state()
        print("Recording cancelled")

    def _reset_state(self):
        """Reset to idle state."""
        self.is_recording = False
        self.is_processing = False
        self.is_llm_mode = False
        self.audio_file = None
        self.audio_frames = []
        # UI updates must happen on main thread
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "resetUI", None, False
        )

    def resetUI(self):
        """Reset UI elements (called on main thread)."""
        self._set_status_icon("idle")
        self.status_menu_item.setTitle_("Ready")

    def _process_audio(self):
        """Process recorded audio (runs in background thread)."""
        if not self.audio_file or not os.path.exists(self.audio_file):
            if self.overlay:
                self.overlay.hide()
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
                        if self.overlay:
                            self.overlay.show_result(response, is_llm=True)
                        self._inject_text(response)
                    else:
                        if self.overlay:
                            self.overlay.show_error("LLM returned no response")
                else:
                    # Direct transcription
                    if self.overlay:
                        self.overlay.show_result(text, is_llm=False)
                    self._inject_text(text)
            else:
                if self.overlay:
                    self.overlay.show_error("No transcription result")
                print("No transcription result")

        except Exception as e:
            print(f"Error processing audio: {e}")
            if self.overlay:
                self.overlay.show_error(str(e))
            # UI update must happen on main thread
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "setErrorIcon", None, False
            )

        finally:
            # Clean up audio file
            if self.audio_file and os.path.exists(self.audio_file):
                os.remove(self.audio_file)

            # Hide overlay after a brief delay to show result
            if self.overlay:
                time.sleep(1.5)
                self.overlay.hide()
            self._reset_state()

    def setErrorIcon(self):
        """Set error icon (called on main thread)."""
        self._set_status_icon("error")

    def _transcribe_audio(self, audio_path: str) -> Optional[str]:
        """Send audio to transcription daemon."""
        socket_path = self.config.get("transcription_socket", "/tmp/dictation_transcription.sock")
        sock = None

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
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass

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
        sock = None

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

            result = json.loads(response.decode().strip())
            return result.get("text", "").strip()

        except (socket.error, json.JSONDecodeError) as e:
            print(f"LLM error: {e}")
            return None
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass

    def _inject_text(self, text: str):
        """Inject text into active application."""
        # Small delay to ensure focus is on target app
        time.sleep(0.1)
        success = self.text_injector.inject_text(text)
        if success:
            print(f"Injected: {text[:50]}...")
        else:
            print("Injection failed")

    # Menu actions - these must be visible to Objective-C (no @objc.python_method)
    @objc.python_method
    def _get_daemon_script(self):
        """Get path to daemon control script."""
        script_dir = Path(__file__).parent
        # Prefer the new macOS-specific script
        mac_script = script_dir / "daemon_control_mac.sh"
        if mac_script.exists():
            return mac_script
        # Fall back to old script
        old_script = script_dir / "daemon_control.sh"
        if old_script.exists():
            return old_script
        return None

    def startDaemons_(self, sender):
        """Start transcription/LLM daemons."""
        script = self._get_daemon_script()
        if script:
            subprocess.run([str(script), "start"])
            time.sleep(1)
            self._update_daemon_status()
        else:
            print("Daemon control script not found")

    def stopDaemons_(self, sender):
        """Stop transcription/LLM daemons."""
        script = self._get_daemon_script()
        if script:
            subprocess.run([str(script), "stop"])
            time.sleep(0.5)
            self._update_daemon_status()
        else:
            print("Daemon control script not found")

    def restartDaemons_(self, sender):
        """Restart transcription/LLM daemons."""
        script = self._get_daemon_script()
        if script:
            subprocess.run([str(script), "restart"])
            time.sleep(1)
            self._update_daemon_status()
        else:
            print("Daemon control script not found")

    def installDaemons_(self, sender):
        """Install launchd services for auto-start."""
        script = self._get_daemon_script()
        if script and "mac" in str(script):
            subprocess.run([str(script), "install"])
            print("Launchd services installed")
        else:
            print("macOS daemon control script not found")

    def uninstallDaemons_(self, sender):
        """Remove launchd services."""
        script = self._get_daemon_script()
        if script and "mac" in str(script):
            subprocess.run([str(script), "uninstall"])
            print("Launchd services removed")
        else:
            print("macOS daemon control script not found")

    def viewLogs_(self, sender):
        """Open log files in Console.app."""
        log_file = os.path.expanduser("~/.dictation_transcription.log")
        if os.path.exists(log_file):
            subprocess.run(["open", "-a", "Console", log_file])
        else:
            print("No log file found")

    def showSettings_(self, sender):
        """Show settings dialog."""
        # TODO: Implement settings UI
        print("Settings not yet implemented")
        # For now, open config file in default editor
        config_file = os.path.expanduser("~/.dictation_config")
        if os.path.exists(config_file):
            subprocess.run(["open", config_file])
        else:
            print(f"Config file not found: {config_file}")
            print(f"Current config: {self.config}")

    def quitApp_(self, sender):
        """Quit the application."""
        # Stop input monitoring
        if self.input_monitor:
            self.input_monitor.stop()
        # Stop overlay
        if self.overlay:
            self.overlay.stop()
        # Cleanup PyAudio
        if self.pyaudio:
            try:
                self.pyaudio.terminate()
            except Exception:
                pass
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
