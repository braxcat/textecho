#!/usr/bin/env python3
"""
Dictation-Mac: Menu bar application for macOS.

Main entry point that coordinates:
- Input monitoring (mouse/keyboard triggers)
- Audio recording
- Transcription via MLX Whisper daemon
- Text injection into active app

Can also run daemons directly when invoked with --daemon flag
(used by .app bundle and launchd).

Usage:
    python3 dictation_app_mac.py                     # Menu bar app
    python3 dictation_app_mac.py --daemon transcription  # Run transcription daemon
    python3 dictation_app_mac.py --daemon llm            # Run LLM daemon
"""

import argparse
import json
import logging
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
from ApplicationServices import AXIsProcessTrustedWithOptions
from CoreFoundation import CFDictionaryCreate, kCFBooleanTrue
from Foundation import NSObject, NSTimer
from AppKit import (
    NSApplication,
    NSStatusBar,
    NSMenu,
    NSMenuItem,
    NSImage,
    NSVariableStatusItemLength,
    NSApplicationActivationPolicyAccessory,
    NSWorkspace,
)

from input_monitor_mac import (
    InputMonitor,
    InputEvent,
    ModifierState,
    MOUSE_BUTTON_MIDDLE,
    MOUSE_BUTTON_BACK,
    MOUSE_BUTTON_FORWARD,
)

# Track keyboard-triggered recording (toggle mode vs mouse hold mode)
KEYBOARD_TRIGGER = "keyboard"
MOUSE_TRIGGER = "mouse"
from text_injector_mac import TextInjector
from overlay_swift import SwiftOverlay
from log_config import setup_logging, get_log_dir
import daemon_manager

logger = logging.getLogger(__name__)

# Default configuration
DEFAULT_CONFIG = {
    "trigger_button": MOUSE_BUTTON_MIDDLE,  # 2=middle, 3=back, 4=forward
    "silence_duration": 2.5,
    "transcription_socket": "/tmp/dictation_transcription.sock",
    "llm_socket": "/tmp/dictation_llm.sock",
    "llm_enabled": False,
}

CONFIG_PATH = Path.home() / ".dictation_config"


def _get_resource_path(relative_path: str) -> Path:
    """Resolve a resource path, handling both source and .app bundle layouts."""
    if getattr(sys, 'frozen', False):
        # Inside .app bundle: resources are in Contents/Resources/
        base = Path(sys.executable).parent.parent / "Resources"
    else:
        # Running from source
        base = Path(__file__).parent
    return base / relative_path


def _check_first_run():
    """On first run, prompt for Accessibility permissions if needed."""
    if AXIsProcessTrustedWithOptions is None:
        return

    # Check if we already have permission
    try:
        from ApplicationServices import AXIsProcessTrusted
        if AXIsProcessTrusted():
            return
    except ImportError:
        return

    # Prompt the user — this shows the system dialog
    options = {
        "AXTrustedCheckOptionPrompt": kCFBooleanTrue,
    }
    try:
        AXIsProcessTrustedWithOptions(options)
    except Exception as e:
        logger.warning("Could not check accessibility trust: %s", e)


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
        self.recording_trigger: Optional[str] = None  # "keyboard" or "mouse"
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

        # Start daemons
        self._auto_start_daemons()

        # Delay input monitor start until after app run loop begins
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, objc.selector(self.delayedStart_, signature=b'v@:@'), None, False
        )

        return self

    def delayedStart_(self, timer):
        """Start input monitoring after app is fully running."""
        self._start_input_monitor()

    @objc.python_method
    def _auto_start_daemons(self):
        """Start transcription daemon (and LLM if enabled) on app launch."""
        daemon_manager.start_daemon("transcription")
        if self.config.get("llm_enabled"):
            daemon_manager.start_daemon("llm")

    def _load_config(self) -> dict:
        """Load configuration from file."""
        config = DEFAULT_CONFIG.copy()
        if CONFIG_PATH.exists():
            try:
                with open(CONFIG_PATH) as f:
                    user_config = json.load(f)
                    config.update(user_config)
            except (json.JSONDecodeError, IOError) as e:
                logger.warning("Could not load config: %s", e)
        return config

    def _save_config(self):
        """Save configuration to file."""
        try:
            with open(CONFIG_PATH, 'w') as f:
                json.dump(self.config, f, indent=2)
        except IOError as e:
            logger.warning("Could not save config: %s", e)

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
        if daemon_manager.check_daemon("transcription"):
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

        if event == InputEvent.TRIGGER_BUTTON_DOWN:
            if modifiers.ctrl:
                self._start_recording(llm_mode=True, trigger=MOUSE_TRIGGER)
            else:
                self._start_recording(llm_mode=False, trigger=MOUSE_TRIGGER)

        elif event == InputEvent.TRIGGER_BUTTON_UP:
            if self.recording_trigger == MOUSE_TRIGGER:
                self._stop_recording()

        elif event == InputEvent.HOTKEY_DICTATE_DOWN:
            if not self.is_recording:
                self._start_recording(llm_mode=False, trigger=KEYBOARD_TRIGGER)

        elif event == InputEvent.HOTKEY_DICTATE_UP:
            if self.is_recording and self.recording_trigger == KEYBOARD_TRIGGER:
                self._stop_recording()

        elif event == InputEvent.HOTKEY_DICTATE_LLM_DOWN:
            if not self.is_recording:
                self._start_recording(llm_mode=True, trigger=KEYBOARD_TRIGGER)

        elif event == InputEvent.HOTKEY_DICTATE_LLM_UP:
            if self.is_recording and self.recording_trigger == KEYBOARD_TRIGGER:
                self._stop_recording()

        elif event == InputEvent.KEY_ESCAPE:
            self._cancel_recording()

        elif event == InputEvent.LEFT_CLICK:
            pass  # TODO: implement for overlay click-to-paste

        elif event == InputEvent.RIGHT_CLICK:
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
            logger.info("Register %d set: %s...", num, content[:50])

    def _clear_registers(self):
        """Clear all registers."""
        self.registers.clear()
        logger.info("All registers cleared")

    def _start_recording(self, llm_mode: bool = False, trigger: str = MOUSE_TRIGGER):
        """Start audio recording."""
        if self.is_recording:
            return

        self.is_recording = True
        self.is_llm_mode = llm_mode
        self.recording_trigger = trigger
        self._set_status_icon("recording")
        self.status_menu_item.setTitle_("Recording...")

        # Reset state
        self.audio_frames = []
        self.stop_recording_flag.clear()

        # Show overlay
        if self.overlay:
            self.overlay.show_recording()

        # Start recording in background thread
        self.recording_thread = threading.Thread(target=self._record_audio, daemon=True)
        self.recording_thread.start()
        logger.info("Recording started (llm=%s, trigger=%s)", llm_mode, trigger)

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

            # Waveform state
            self._waveform_levels = [0.05] * 40
            self._pending_level = None

            def waveform_updater():
                while not self.stop_recording_flag.is_set():
                    if self._pending_level is not None and self.overlay:
                        level = self._pending_level
                        self._pending_level = None
                        self._waveform_levels.pop(0)
                        self._waveform_levels.append(level)
                        self.overlay.update_waveform(list(self._waveform_levels))
                    time.sleep(0.05)

            waveform_thread = threading.Thread(target=waveform_updater, daemon=True)
            waveform_thread.start()

            while not self.stop_recording_flag.is_set():
                data = stream.read(self.chunk_size, exception_on_overflow=False)
                self.audio_frames.append(data)

                audio_data = np.frombuffer(data, dtype=np.int16)
                rms = np.sqrt(np.mean(audio_data.astype(np.float32) ** 2))
                level = min(rms / 2000, 1.0)
                level = np.sqrt(level)
                self._pending_level = float(level)

        except Exception as e:
            logger.error("Recording error: %s", e)
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
            try:
                tmp = tempfile.NamedTemporaryFile(
                    suffix=".wav", prefix="dictation_", delete=False
                )
                self.audio_file = tmp.name
                tmp.close()
                self._save_audio_to_file(self.audio_file)
                logger.info("Recording stopped, saved to %s", self.audio_file)
            except Exception as e:
                logger.error("Failed to save audio: %s", e)
                if self.overlay:
                    self.overlay.hide()
                self._reset_state()
                return

            # Show processing state
            if self.overlay:
                self.overlay.show_processing()

            # Process in background thread
            threading.Thread(target=self._process_audio, daemon=True).start()
        else:
            logger.info("No audio recorded")
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
        self.stop_recording_flag.set()

        if self.recording_thread:
            self.recording_thread.join(timeout=1.0)
            self.recording_thread = None

        # Clear audio frames without saving
        self.audio_frames = []

        if self.audio_file and os.path.exists(self.audio_file):
            try:
                os.remove(self.audio_file)
            except OSError:
                pass

        if self.overlay:
            self.overlay.hide()
        self._reset_state()
        logger.info("Recording cancelled")

    def _reset_state(self):
        """Reset to idle state."""
        self.is_recording = False
        self.is_processing = False
        self.is_llm_mode = False
        self.recording_trigger = None
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
            text = self._transcribe_audio(self.audio_file)

            if text:
                if self.is_llm_mode and self.config.get("llm_enabled"):
                    response = self._query_llm(text)
                    if response:
                        if self.overlay:
                            self.overlay.show_result(response, is_llm=True)
                        self._inject_text(response)
                    else:
                        if self.overlay:
                            self.overlay.show_error("LLM returned no response")
                else:
                    if self.overlay:
                        self.overlay.show_result(text, is_llm=False)
                    self._inject_text(text)
            else:
                if self.overlay:
                    self.overlay.show_error("No transcription result")
                logger.warning("No transcription result")

        except Exception as e:
            logger.error("Error processing audio: %s", e)
            if self.overlay:
                self.overlay.show_error(str(e))
            self.performSelectorOnMainThread_withObject_waitUntilDone_(
                "setErrorIcon", None, False
            )

        finally:
            # Clean up audio file
            if self.audio_file and os.path.exists(self.audio_file):
                try:
                    os.remove(self.audio_file)
                except OSError:
                    pass

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
            sock.settimeout(30)
            sock.connect(socket_path)

            request = {"command": "transcribe", "audio_file": audio_path}
            sock.sendall(json.dumps(request).encode() + b'\n')

            response = b''
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                response += chunk
                if b'\n' in response:
                    break

            if not response.strip():
                logger.warning("Empty response from daemon")
                return None

            result = json.loads(response.decode().strip())

            if result.get("success"):
                return result.get("transcription", "").strip()
            else:
                logger.error("Transcription failed: %s", result.get("error"))
                return None

        except socket.timeout:
            logger.error("Transcription timeout")
            return None
        except (socket.error, json.JSONDecodeError) as e:
            logger.error("Transcription error: %s", e)
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

            request = {
                "prompt": prompt,
                "context": context
            }
            sock.sendall(json.dumps(request).encode() + b'\n')

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
            logger.error("LLM error: %s", e)
            return None
        finally:
            if sock:
                try:
                    sock.close()
                except Exception:
                    pass

    def _inject_text(self, text: str):
        """Inject text into active application."""
        time.sleep(0.1)
        success = self.text_injector.inject_text(text)
        if success:
            logger.info("Injected: %s...", text[:50])
        else:
            logger.warning("Injection failed")

    # Menu actions

    def startDaemons_(self, sender):
        """Start transcription/LLM daemons."""
        threading.Thread(target=self._do_start_daemons, daemon=True).start()

    @objc.python_method
    def _do_start_daemons(self):
        daemon_manager.start_daemon("transcription")
        if self.config.get("llm_enabled"):
            daemon_manager.start_daemon("llm")
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "updateDaemonStatusUI", None, False
        )

    def stopDaemons_(self, sender):
        """Stop transcription/LLM daemons."""
        threading.Thread(target=self._do_stop_daemons, daemon=True).start()

    @objc.python_method
    def _do_stop_daemons(self):
        daemon_manager.stop_all_daemons()
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "updateDaemonStatusUI", None, False
        )

    def restartDaemons_(self, sender):
        """Restart transcription/LLM daemons."""
        threading.Thread(target=self._do_restart_daemons, daemon=True).start()

    @objc.python_method
    def _do_restart_daemons(self):
        daemon_manager.stop_all_daemons()
        time.sleep(0.5)
        daemon_manager.start_daemon("transcription")
        if self.config.get("llm_enabled"):
            daemon_manager.start_daemon("llm")
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "updateDaemonStatusUI", None, False
        )

    def updateDaemonStatusUI(self):
        """Update daemon status on main thread."""
        self._update_daemon_status()

    def installDaemons_(self, sender):
        """Install launchd services for auto-start."""
        daemon_manager.install_launchd()
        logger.info("Launchd services installed")

    def uninstallDaemons_(self, sender):
        """Remove launchd services."""
        daemon_manager.uninstall_launchd()
        logger.info("Launchd services removed")

    def viewLogs_(self, sender):
        """Open log directory in Finder."""
        log_dir = get_log_dir()
        log_dir.mkdir(parents=True, exist_ok=True)
        NSWorkspace.sharedWorkspace().openFile_(str(log_dir))

    def showSettings_(self, sender):
        """Show settings dialog."""
        # TODO: Implement settings UI
        logger.info("Settings not yet implemented")
        config_file = str(CONFIG_PATH)
        if os.path.exists(config_file):
            subprocess.run(["open", config_file])
        else:
            logger.info("Config file not found: %s", config_file)

    def quitApp_(self, sender):
        """Quit the application."""
        logger.info("Quitting application...")
        # Stop input monitoring (fast)
        if self.input_monitor:
            try:
                self.input_monitor.stop()
            except Exception:
                pass
        # Stop overlay (fast)
        if self.overlay:
            try:
                self.overlay.stop()
            except Exception:
                pass
        # Cleanup PyAudio (fast)
        if self.pyaudio:
            try:
                self.pyaudio.terminate()
            except Exception:
                pass
        # Stop daemons in background — don't block the quit
        threading.Thread(target=daemon_manager.stop_all_daemons, daemon=True).start()
        # Terminate immediately
        NSApplication.sharedApplication().terminate_(None)


def _run_daemon(daemon_type: str):
    """Run a daemon process directly (called via --daemon flag)."""
    setup_logging(daemon_type)

    # Ensure bundled dylibs (e.g. libsndfile) are discoverable via dlopen.
    # py2app puts them in Contents/Frameworks/ but cffi's ffi.dlopen() only
    # checks DYLD_FALLBACK_LIBRARY_PATH, not ctypes default paths.
    if getattr(sys, 'frozen', False):
        frameworks_dir = os.path.join(
            os.path.dirname(sys.executable), '..', 'Frameworks'
        )
        existing = os.environ.get('DYLD_FALLBACK_LIBRARY_PATH', '')
        os.environ['DYLD_FALLBACK_LIBRARY_PATH'] = (
            os.path.abspath(frameworks_dir) +
            (':' + existing if existing else '')
        )

    if daemon_type == "transcription":
        from transcription_daemon_mlx import TranscriptionDaemon
        daemon = TranscriptionDaemon()
        daemon.run()
    elif daemon_type == "llm":
        from llm_daemon import LLMDaemon
        daemon = LLMDaemon()
        daemon.run()
    else:
        logger.error("Unknown daemon type: %s", daemon_type)
        sys.exit(1)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(description="Dictation-Mac")
    parser.add_argument(
        "--daemon",
        choices=["transcription", "llm"],
        help="Run as a daemon process instead of the menu bar app",
    )
    args = parser.parse_args()

    if args.daemon:
        _run_daemon(args.daemon)
        return

    # Menu bar app mode
    setup_logging("app")

    logger.info("=" * 50)
    logger.info("Dictation-Mac")
    logger.info("=" * 50)

    # First-run accessibility check
    _check_first_run()

    # Create application
    app = NSApplication.sharedApplication()

    # Set as accessory app (no dock icon)
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    # Create our delegate
    delegate = DictationApp.alloc().init()
    app.setDelegate_(delegate)

    logger.info("Running... (Cmd+Q or menu to quit)")

    # Run the app
    app.run()


if __name__ == "__main__":
    main()
