#!/usr/bin/env python3
"""
TextEcho: Menu bar application for macOS.

Main entry point that coordinates:
- Input monitoring (mouse/keyboard triggers)
- Audio recording
- Transcription via MLX Whisper daemon
- Text injection into active app

Can also run daemons directly when invoked with --daemon flag
(used by .app bundle and launchd).

Usage:
    python3 textecho_app_mac.py                     # Menu bar app
    python3 textecho_app_mac.py --daemon transcription  # Run transcription daemon
    python3 textecho_app_mac.py --daemon llm            # Run LLM daemon

Author: Braxton Bragg
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
from Foundation import NSObject, NSTimer, NSBundle
from AppKit import (
    NSApplication,
    NSStatusBar,
    NSMenu,
    NSMenuItem,
    NSImage,
    NSVariableStatusItemLength,
    NSApplicationActivationPolicyAccessory,
    NSWorkspace,
    NSWindow,
    NSWindowStyleMaskTitled,
    NSWindowStyleMaskClosable,
    NSBackingStoreBuffered,
    NSTextField,
    NSButton,
    NSBezelStyleRounded,
    NSProgressIndicator,
    NSProgressIndicatorSpinningStyle,
    NSColor,
    NSFont,
    NSView,
    NSTextAlignmentCenter,
)
from Quartz import CGRectMake

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
    "transcription_socket": "/tmp/textecho_transcription.sock",
    "llm_socket": "/tmp/textecho_llm.sock",
    "llm_enabled": False,
    "input_device": None,  # None = auto-detect, or device index/name
}

CONFIG_PATH = Path.home() / ".textecho_config"


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
    """Legacy first-run check — kept for non-wizard accessibility prompt.

    The setup wizard now handles first-run setup. This only runs on
    subsequent launches to re-prompt if accessibility was revoked.
    """
    if AXIsProcessTrustedWithOptions is None:
        return

    try:
        from ApplicationServices import AXIsProcessTrusted
        if AXIsProcessTrusted():
            return
    except ImportError:
        return

    options = {
        "AXTrustedCheckOptionPrompt": kCFBooleanTrue,
    }
    try:
        AXIsProcessTrustedWithOptions(options)
    except Exception as e:
        logger.warning("Could not check accessibility trust: %s", e)


class SetupWizard(NSObject):
    """First-run setup wizard that guides users through permissions and model loading."""

    # Tokyo Night colors
    BG_COLOR = (0x1a / 255, 0x1b / 255, 0x26 / 255)  # #1a1b26
    TEXT_COLOR = (0xa9 / 255, 0xb1 / 255, 0xd6 / 255)  # #a9b1d6
    ACCENT_COLOR = (0x7a / 255, 0xa2 / 255, 0xf7 / 255)  # #7aa2f7
    GREEN_COLOR = (0x9e / 255, 0xce / 255, 0x6a / 255)  # #9ece6a
    DIM_COLOR = (0x56 / 255, 0x5f / 255, 0x89 / 255)  # #565f89

    WINDOW_WIDTH = 520
    WINDOW_HEIGHT = 380
    TOTAL_STEPS = 5  # Progress dots (Welcome, Accessibility, Microphone, Model, Input Monitoring)

    def initWithCallback_(self, callback):
        self = objc.super(SetupWizard, self).init()
        if self is None:
            return None

        self._completion_callback = callback
        self._current_step = 0
        self._polling_timer = None
        self._preload_thread = None
        self._progress_timer = None
        self._model_load_start_time = None
        self._model_loaded = False
        # Estimated time for model loading (first run ~60s download + load, subsequent ~10s cache)
        self._estimated_model_time = 60.0

        self._create_window()
        self._show_step(0)

        return self

    @objc.python_method
    def _make_color(self, rgb):
        return NSColor.colorWithCalibratedRed_green_blue_alpha_(rgb[0], rgb[1], rgb[2], 1.0)

    @objc.python_method
    def _create_window(self):
        """Create the setup wizard window."""
        frame = CGRectMake(0, 0, self.WINDOW_WIDTH, self.WINDOW_HEIGHT)
        style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        self.window = NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            frame, style, NSBackingStoreBuffered, False
        )
        self.window.setTitle_("TextEcho Setup")
        self.window.center()
        self.window.setReleasedWhenClosed_(False)
        self.window.setDelegate_(self)

        # Force dark appearance so all controls render with dark theme
        dark_appearance = AppKit.NSAppearance.appearanceNamed_("NSAppearanceNameDarkAqua")
        self.window.setAppearance_(dark_appearance)

        # Dark background (Tokyo Night)
        content = self.window.contentView()
        content.setWantsLayer_(True)
        content.layer().setBackgroundColor_(
            NSColor.colorWithCalibratedRed_green_blue_alpha_(
                *self.BG_COLOR, 1.0
            ).CGColor()
        )

        # Step indicator dots
        self._dot_views = []
        dot_y = self.WINDOW_HEIGHT - 45
        dot_start_x = (self.WINDOW_WIDTH - (self.TOTAL_STEPS * 20)) / 2
        for i in range(self.TOTAL_STEPS):
            dot = NSTextField.alloc().initWithFrame_(CGRectMake(dot_start_x + i * 20, dot_y, 14, 14))
            dot.setBezeled_(False)
            dot.setDrawsBackground_(False)
            dot.setEditable_(False)
            dot.setSelectable_(False)
            dot.setAlignment_(NSTextAlignmentCenter)
            dot.setStringValue_("●")
            dot.setFont_(NSFont.systemFontOfSize_(10))
            dot.setTextColor_(self._make_color(self.DIM_COLOR))
            content.addSubview_(dot)
            self._dot_views.append(dot)

        # Title label
        self._title_label = NSTextField.alloc().initWithFrame_(
            CGRectMake(40, self.WINDOW_HEIGHT - 110, self.WINDOW_WIDTH - 80, 40)
        )
        self._title_label.setBezeled_(False)
        self._title_label.setDrawsBackground_(False)
        self._title_label.setEditable_(False)
        self._title_label.setSelectable_(False)
        self._title_label.setAlignment_(NSTextAlignmentCenter)
        self._title_label.setFont_(NSFont.boldSystemFontOfSize_(24))
        self._title_label.setTextColor_(self._make_color(self.TEXT_COLOR))
        content.addSubview_(self._title_label)

        # Description label
        self._desc_label = NSTextField.alloc().initWithFrame_(
            CGRectMake(50, self.WINDOW_HEIGHT - 220, self.WINDOW_WIDTH - 100, 90)
        )
        self._desc_label.setBezeled_(False)
        self._desc_label.setDrawsBackground_(False)
        self._desc_label.setEditable_(False)
        self._desc_label.setSelectable_(False)
        self._desc_label.setAlignment_(NSTextAlignmentCenter)
        self._desc_label.setFont_(NSFont.systemFontOfSize_(14))
        self._desc_label.setTextColor_(self._make_color(self.TEXT_COLOR))
        content.addSubview_(self._desc_label)

        # Status label (for checkmarks / status messages)
        self._status_label = NSTextField.alloc().initWithFrame_(
            CGRectMake(50, self.WINDOW_HEIGHT - 260, self.WINDOW_WIDTH - 100, 30)
        )
        self._status_label.setBezeled_(False)
        self._status_label.setDrawsBackground_(False)
        self._status_label.setEditable_(False)
        self._status_label.setSelectable_(False)
        self._status_label.setAlignment_(NSTextAlignmentCenter)
        self._status_label.setFont_(NSFont.systemFontOfSize_(14))
        self._status_label.setTextColor_(self._make_color(self.GREEN_COLOR))
        self._status_label.setStringValue_("")
        content.addSubview_(self._status_label)

        # Spinner (hidden by default)
        self._spinner = NSProgressIndicator.alloc().initWithFrame_(
            CGRectMake((self.WINDOW_WIDTH - 32) / 2, self.WINDOW_HEIGHT - 260, 32, 32)
        )
        self._spinner.setStyle_(NSProgressIndicatorSpinningStyle)
        self._spinner.setControlSize_(1)  # NSControlSizeRegular
        self._spinner.setDisplayedWhenStopped_(False)
        content.addSubview_(self._spinner)

        # Progress bar for model loading (hidden by default)
        self._progress_bar = NSProgressIndicator.alloc().initWithFrame_(
            CGRectMake(60, self.WINDOW_HEIGHT - 290, self.WINDOW_WIDTH - 120, 20)
        )
        self._progress_bar.setStyle_(0)  # NSProgressIndicatorStyleBar
        self._progress_bar.setIndeterminate_(True)
        self._progress_bar.setHidden_(True)
        content.addSubview_(self._progress_bar)

        # Main action button
        self._action_button = NSButton.alloc().initWithFrame_(
            CGRectMake((self.WINDOW_WIDTH - 200) / 2, 40, 200, 40)
        )
        self._action_button.setBezelStyle_(NSBezelStyleRounded)
        self._action_button.setFont_(NSFont.systemFontOfSize_(15))
        self._action_button.setTarget_(self)
        self._action_button.setAction_(objc.selector(self.actionButtonClicked_, signature=b'v@:@'))
        content.addSubview_(self._action_button)

    @objc.python_method
    def _update_dots(self, step):
        """Update step indicator dots."""
        for i, dot in enumerate(self._dot_views):
            if i < step:
                dot.setTextColor_(self._make_color(self.GREEN_COLOR))
            elif i == step:
                dot.setTextColor_(self._make_color(self.ACCENT_COLOR))
            else:
                dot.setTextColor_(self._make_color(self.DIM_COLOR))

    @objc.python_method
    def _show_step(self, step):
        """Show the given step in the wizard."""
        self._current_step = step
        self._stop_polling()
        # Stop progress timer if running
        if self._progress_timer:
            self._progress_timer.invalidate()
            self._progress_timer = None
        self._spinner.stopAnimation_(None)
        self._spinner.setHidden_(False)
        self._progress_bar.stopAnimation_(None)
        self._progress_bar.setIndeterminate_(True)  # Reset to indeterminate
        self._progress_bar.setHidden_(True)
        self._status_label.setStringValue_("")
        self._action_button.setEnabled_(True)

        # Map step index to dot index (step 4 "Ready" shares dot 3 with model loading)
        dot_index = min(step, self.TOTAL_STEPS - 1)
        self._update_dots(dot_index)

        # New order: Welcome → Accessibility → Microphone → Model → Input Monitoring → Ready
        # Input Monitoring is last because it requires app restart
        if step == 0:
            self._show_welcome()
        elif step == 1:
            self._show_accessibility()
        elif step == 2:
            self._show_microphone()
        elif step == 3:
            self._show_model_loading()
        elif step == 4:
            self._show_input_monitoring()
        elif step == 5:
            self._show_ready()

    @objc.python_method
    def _show_welcome(self):
        self._title_label.setStringValue_("Welcome to TextEcho")
        self._desc_label.setStringValue_(
            "Voice-to-text dictation for macOS.\n\n"
            "This wizard will help you set up the required\n"
            "permissions and load the speech recognition model."
        )
        self._action_button.setTitle_("Get Started")

    @objc.python_method
    def _show_accessibility(self):
        self._title_label.setStringValue_("Accessibility Permission")
        self._desc_label.setStringValue_(
            "TextEcho needs Accessibility access to detect\n"
            "mouse/keyboard input and paste text.\n\n"
            "Click \"Grant Access\" to open System Settings,\n"
            "then toggle the switch for this app."
        )
        self._action_button.setTitle_("Grant Access")

        # Check if already granted
        try:
            from ApplicationServices import AXIsProcessTrusted
            if AXIsProcessTrusted():
                self._on_accessibility_granted()
                return
        except ImportError:
            pass

    @objc.python_method
    def _show_input_monitoring(self):
        self._title_label.setStringValue_("Input Monitoring Permission")
        self._desc_label.setStringValue_(
            "TextEcho needs Input Monitoring access to\n"
            "detect mouse button clicks.\n\n"
            "1. Click \"Open Settings\" below\n"
            "2. Click the + button in Settings\n"
            "3. Select TextEcho from Applications\n"
            "4. Click Continue when done"
        )
        self._action_button.setTitle_("Open Settings")
        self._status_label.setStringValue_("")

    @objc.python_method
    def _show_microphone(self):
        self._title_label.setStringValue_("Microphone Permission")
        self._desc_label.setStringValue_(
            "TextEcho needs Microphone access to record\n"
            "audio for transcription.\n\n"
            "Click \"Grant Access\" to trigger the permission\n"
            "dialog, then click \"Allow\"."
        )
        self._action_button.setTitle_("Grant Access")

        # Check if already granted
        if self._check_mic_permission():
            self._on_microphone_granted()

    @objc.python_method
    def _show_model_loading(self):
        self._title_label.setStringValue_("Loading Speech Model")
        self._desc_label.setStringValue_(
            "Pre-loading the speech recognition model.\n\n"
            "First run will download ~150MB.\n"
            "Subsequent runs load from cache."
        )
        self._action_button.setTitle_("Continue")
        self._action_button.setEnabled_(False)
        self._spinner.setHidden_(True)
        self._spinner.stopAnimation_(None)

        # Set up determinate progress bar with countdown
        self._model_loaded = False
        self._model_load_start_time = time.time()
        self._progress_bar.setIndeterminate_(False)
        self._progress_bar.setMinValue_(0.0)
        self._progress_bar.setMaxValue_(100.0)
        self._progress_bar.setDoubleValue_(0.0)
        self._progress_bar.setHidden_(False)

        remaining = int(self._estimated_model_time)
        self._status_label.setStringValue_(f"~{remaining} seconds remaining...")
        self._status_label.setTextColor_(self._make_color(self.TEXT_COLOR))

        # Start progress timer (updates every 0.5 seconds)
        self._progress_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.5, self, objc.selector(self.updateModelProgress_, signature=b'v@:@'), None, True
        )

        # Start preload in background
        self._preload_thread = threading.Thread(target=self._do_preload_model, daemon=True)
        self._preload_thread.start()

    def updateModelProgress_(self, timer):
        """Update the model loading progress bar and countdown."""
        if self._model_loaded:
            return

        elapsed = time.time() - self._model_load_start_time
        # Progress asymptotically approaches 95% (never shows 100% until actually done)
        progress = min(95.0, (elapsed / self._estimated_model_time) * 100.0)
        self._progress_bar.setDoubleValue_(progress)

        remaining = max(0, int(self._estimated_model_time - elapsed))
        if remaining > 0:
            self._status_label.setStringValue_(f"~{remaining} seconds remaining...")
        else:
            # Past estimated time, show "almost done"
            self._status_label.setStringValue_("Almost done...")

    @objc.python_method
    def _show_ready(self):
        self._update_dots(self.TOTAL_STEPS)  # All green
        for dot in self._dot_views:
            dot.setTextColor_(self._make_color(self.GREEN_COLOR))

        self._title_label.setStringValue_("Setup Complete!")
        self._desc_label.setStringValue_(
            "TextEcho needs to restart to activate.\n\n"
            "After restart:\n"
            "• Hold Middle-click to dictate and paste text\n"
            "• Hold Ctrl+D for keyboard-only dictation"
        )
        self._status_label.setStringValue_("✓ All permissions granted  ✓ Model loaded")
        self._action_button.setTitle_("Restart TextEcho")

    def actionButtonClicked_(self, sender):
        """Handle the main action button click."""
        step = self._current_step

        # New order: Welcome(0) → Accessibility(1) → Microphone(2) → Model(3) → Input Monitoring(4) → Ready(5)
        if step == 0:
            # Welcome → Accessibility
            self._show_step(1)

        elif step == 1:
            # Grant Accessibility
            self._request_accessibility()

        elif step == 2:
            # Grant Microphone
            self._request_microphone()

        elif step == 3:
            # Model loading in progress — button should be disabled
            pass

        elif step == 4:
            # Open Input Monitoring settings
            self._request_input_monitoring()

        elif step == 5:
            # Ready → write config and restart app
            self._finish_and_restart()

        elif step == 102:
            # Input Monitoring continue → Ready
            self._show_step(5)

    @objc.python_method
    def _request_accessibility(self):
        """Request accessibility permission and start polling."""
        self._action_button.setEnabled_(False)
        self._status_label.setStringValue_("Waiting for permission...")

        # Start polling immediately — don't wait for the prompt call to return
        self._start_polling("accessibility")

        # Run AXIsProcessTrustedWithOptions on a background thread —
        # with the prompt option it can block the main thread on macOS 26.
        def request_ax():
            try:
                options = {"AXTrustedCheckOptionPrompt": kCFBooleanTrue}
                AXIsProcessTrustedWithOptions(options)
            except Exception as e:
                logger.warning("Could not request accessibility: %s", e)

        threading.Thread(target=request_ax, daemon=True).start()

    @objc.python_method
    def _request_input_monitoring(self):
        """Open Input Monitoring settings panel."""
        # Open System Settings to Input Monitoring
        # x-apple.systempreferences URLs work on macOS 13+
        url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        NSWorkspace.sharedWorkspace().openURL_(AppKit.NSURL.URLWithString_(url))

        # Also reveal the app in Finder so user can drag it if needed
        app_path = "/Applications/TextEcho.app"
        if os.path.exists(app_path):
            NSWorkspace.sharedWorkspace().selectFile_inFileViewerRootedAtPath_(app_path, "")

        # Change button to "Continue" so user can proceed after adding permission
        self._action_button.setTitle_("Continue")
        self._status_label.setStringValue_("Click + in Settings, add TextEcho, then Continue")

        # Set a flag so next click advances to microphone step
        self._current_step = 102  # Sentinel for "input monitoring done"

    def advanceToMicFromInputMonitoring_(self, timer):
        self._show_step(3)

    @objc.python_method
    def _request_microphone(self):
        """Trigger microphone permission dialog by briefly opening a stream."""
        self._action_button.setEnabled_(False)
        self._status_label.setStringValue_("Waiting for permission...")

        # Start polling immediately — don't wait for the trigger to complete
        self._start_polling("microphone")

        # Trigger the permission dialog on a background thread
        def trigger_mic():
            try:
                pa = pyaudio.PyAudio()
                stream = pa.open(
                    format=pyaudio.paInt16,
                    channels=1,
                    rate=16000,
                    input=True,
                    frames_per_buffer=1024,
                )
                stream.read(1024, exception_on_overflow=False)
                stream.stop_stream()
                stream.close()
                pa.terminate()
            except Exception as e:
                logger.warning("Mic permission trigger error: %s", e)

        threading.Thread(target=trigger_mic, daemon=True).start()

    @objc.python_method
    def _check_mic_permission(self) -> bool:
        """Check if microphone permission is granted."""
        # Try AVFoundation first
        try:
            import AVFoundation
            status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
                AVFoundation.AVMediaTypeAudio
            )
            logger.debug("AVFoundation mic status: %s", status)
            if status == 3:  # AVAuthorizationStatusAuthorized
                return True
        except Exception as e:
            logger.debug("AVFoundation mic check failed: %s", e)

        # Fallback: try opening a PyAudio stream — if it works, permission is granted
        try:
            pa = pyaudio.PyAudio()
            stream = pa.open(
                format=pyaudio.paInt16, channels=1, rate=16000,
                input=True, frames_per_buffer=512,
            )
            stream.read(512, exception_on_overflow=False)
            stream.stop_stream()
            stream.close()
            pa.terminate()
            return True
        except Exception:
            pass

        return False

    @objc.python_method
    def _start_polling(self, permission_type: str):
        """Start polling for permission changes."""
        self._polling_type = permission_type
        self._polling_timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0, self, objc.selector(self.pollPermission_, signature=b'v@:@'), None, True
        )

    @objc.python_method
    def _stop_polling(self):
        if self._polling_timer:
            self._polling_timer.invalidate()
            self._polling_timer = None

    def pollPermission_(self, timer):
        """Poll for permission status (called by timer)."""
        ptype = getattr(self, '_polling_type', None)
        logger.debug("Polling permission: %s", ptype)

        if ptype == "accessibility":
            try:
                from ApplicationServices import AXIsProcessTrusted
                trusted = AXIsProcessTrusted()
                logger.debug("AXIsProcessTrusted: %s", trusted)
                if trusted:
                    self._stop_polling()
                    self._on_accessibility_granted()
            except ImportError:
                self._stop_polling()
                self._show_step(2)

        elif ptype == "microphone":
            granted = self._check_mic_permission()
            logger.debug("Mic permission granted: %s", granted)
            if granted:
                self._stop_polling()
                self._on_microphone_granted()

    @objc.python_method
    def _on_accessibility_granted(self):
        """Called when accessibility permission is detected."""
        self._status_label.setStringValue_("✓ Accessibility Granted!")
        self._status_label.setTextColor_(self._make_color(self.GREEN_COLOR))
        self._action_button.setTitle_("Continue")
        self._action_button.setEnabled_(True)
        # Override action to go to next step
        self._current_step = 100  # Sentinel

        # Use a short delay then advance to Microphone (step 2)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.8, self, objc.selector(self.advanceToMicrophone_, signature=b'v@:@'), None, False
        )

    def advanceToMicrophone_(self, timer):
        self._show_step(2)

    @objc.python_method
    def _on_microphone_granted(self):
        """Called when microphone permission is detected."""
        self._status_label.setStringValue_("✓ Microphone Granted!")
        self._status_label.setTextColor_(self._make_color(self.GREEN_COLOR))
        self._action_button.setTitle_("Continue")
        self._action_button.setEnabled_(True)
        self._current_step = 101  # Sentinel

        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.8, self, objc.selector(self.advanceToModel_, signature=b'v@:@'), None, False
        )

    def advanceToModel_(self, timer):
        self._show_step(3)  # Model loading is step 3

    @objc.python_method
    def _update_model_status(self, message):
        """Update status label from background thread."""
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "updateModelStatusLabel:", message, False
        )

    def updateModelStatusLabel_(self, message):
        """Called on main thread to update status."""
        self._status_label.setStringValue_(message)

    @objc.python_method
    def _do_preload_model(self):
        """Send preload command to transcription daemon (runs in background thread)."""
        socket_path = "/tmp/textecho_transcription.sock"
        max_attempts = 60  # Wait up to 60 seconds for daemon (download can be slow)
        attempt = 0

        while attempt < max_attempts:
            try:
                self._update_model_status(f"Connecting to daemon... ({attempt + 1}s)")

                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(180)  # Model loading/download can be slow
                sock.connect(socket_path)

                self._update_model_status("Downloading/loading model...")

                request = {"command": "preload"}
                sock.sendall(json.dumps(request).encode() + b'\n')

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
                    # Daemon didn't recognize command (old version) — try status instead
                    logger.info("Empty preload response, trying status fallback")
                    attempt += 1
                    time.sleep(1)
                    continue

                result = json.loads(response.decode().strip())

                if result.get("success") or result.get("model_loaded"):
                    self.performSelectorOnMainThread_withObject_waitUntilDone_(
                        "onModelLoaded", None, False
                    )
                    return
                else:
                    logger.warning("Preload returned: %s", result)
                    attempt += 1
                    time.sleep(1)

            except (socket.error, ConnectionRefusedError, FileNotFoundError):
                # Daemon not ready yet, wait and retry
                attempt += 1
                time.sleep(1)
            except Exception as e:
                logger.error("Preload error: %s", e)
                attempt += 1
                time.sleep(1)

        # Failed after all attempts — let user continue anyway
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "onModelLoadFailed", None, False
        )

    def onModelLoaded(self):
        """Called on main thread when model is loaded."""
        self._model_loaded = True
        if self._progress_timer:
            self._progress_timer.invalidate()
            self._progress_timer = None
        self._spinner.stopAnimation_(None)
        self._progress_bar.setDoubleValue_(100.0)  # Complete the progress bar
        self._progress_bar.setHidden_(True)
        self._status_label.setStringValue_("✓ Model Ready!")
        self._status_label.setTextColor_(self._make_color(self.GREEN_COLOR))
        self._action_button.setEnabled_(True)
        self._action_button.setTitle_("Continue")
        self._current_step = 103  # Sentinel for model loaded

        # Advance to Input Monitoring (step 4)
        NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            0.8, self, objc.selector(self.advanceToInputMonitoring_, signature=b'v@:@'), None, False
        )

    def advanceToInputMonitoring_(self, timer):
        self._show_step(4)  # Input Monitoring

    def advanceToReady_(self, timer):
        self._show_step(5)

    def onModelLoadFailed(self):
        """Called on main thread if model loading failed."""
        self._model_loaded = True  # Prevent timer from continuing
        if self._progress_timer:
            self._progress_timer.invalidate()
            self._progress_timer = None
        self._spinner.stopAnimation_(None)
        self._progress_bar.setHidden_(True)
        self._status_label.setStringValue_("Model will download on first use")
        self._status_label.setTextColor_(self._make_color(self.DIM_COLOR))
        self._action_button.setEnabled_(True)
        self._action_button.setTitle_("Continue Anyway")
        self._current_step = 103  # Same sentinel - advance to Input Monitoring

    @objc.python_method
    def _finish(self):
        """Complete the wizard — write default config and notify callback."""
        self._stop_polling()
        if self._progress_timer:
            self._progress_timer.invalidate()
            self._progress_timer = None
        self._did_finish = True

        # Write default config
        config = DEFAULT_CONFIG.copy()
        try:
            with open(CONFIG_PATH, 'w') as f:
                json.dump(config, f, indent=2)
            logger.info("Default config written to %s", CONFIG_PATH)
        except IOError as e:
            logger.warning("Could not write config: %s", e)

        # Destroy the window and all subviews to fully clean up TSM state
        # (NSTextFields register with Text Services Manager; leaving them
        # alive causes pynput's background thread to crash in TSMGetInputSourceProperty)
        self.window.orderOut_(None)
        for subview in list(self.window.contentView().subviews()):
            subview.removeFromSuperview()
        self.window.setContentView_(NSView.alloc().initWithFrame_(CGRectMake(0, 0, 1, 1)))
        self.window.close()
        self.window = None

        # Clear all our view references
        self._dot_views = []
        self._title_label = None
        self._desc_label = None
        self._status_label = None
        self._spinner = None
        self._action_button = None

        # Fire callback AFTER window is fully torn down, using a timer
        # to ensure the current run loop iteration completes first
        if self._completion_callback:
            cb = self._completion_callback
            self._completion_callback = None
            # Use performSelector to defer callback to next run loop iteration
            AppKit.NSObject.cancelPreviousPerformRequestsWithTarget_(self)
            self._deferred_callback = cb
            self.performSelector_withObject_afterDelay_(
                objc.selector(self._fireCallback, signature=b'v@:'), None, 0.1
            )

    def _fireCallback(self):
        """Fire the deferred completion callback."""
        cb = getattr(self, '_deferred_callback', None)
        if cb:
            self._deferred_callback = None
            cb()

    @objc.python_method
    def _finish_and_restart(self):
        """Complete wizard, write config, and restart app."""
        self._stop_polling()
        if self._progress_timer:
            self._progress_timer.invalidate()
            self._progress_timer = None
        self._did_finish = True

        # Write default config
        config = DEFAULT_CONFIG.copy()
        try:
            with open(CONFIG_PATH, 'w') as f:
                json.dump(config, f, indent=2)
            logger.info("Default config written to %s", CONFIG_PATH)
        except IOError as e:
            logger.warning("Could not write config: %s", e)

        # Restart the app (fresh process state, no TSM conflicts)
        self._restart_app()

    @objc.python_method
    def _restart_app(self):
        """Restart the application to apply permissions."""
        app_path = NSBundle.mainBundle().bundlePath()
        logger.info("Restarting app from: %s", app_path)
        # Use open command to restart the app after a short delay
        subprocess.Popen(['bash', '-c', f'sleep 0.5 && open "{app_path}"'])
        # Quit this instance
        NSApplication.sharedApplication().terminate_(None)

    def show(self):
        """Show the wizard window."""
        self._did_finish = False
        self.window.makeKeyAndOrderFront_(None)
        NSApplication.sharedApplication().activateIgnoringOtherApps_(True)

    def windowWillClose_(self, notification):
        """Handle window close (user clicking X)."""
        self._stop_polling()
        if not getattr(self, '_did_finish', False):
            self._did_finish = True
            if not CONFIG_PATH.exists():
                config = DEFAULT_CONFIG.copy()
                try:
                    with open(CONFIG_PATH, 'w') as f:
                        json.dump(config, f, indent=2)
                except IOError:
                    pass
            # Remove all subviews to clean up TSM state
            if self.window:
                for subview in list(self.window.contentView().subviews()):
                    subview.removeFromSuperview()
            if self._completion_callback:
                cb = self._completion_callback
                self._completion_callback = None
                cb()


class TextEchoApp(NSObject):
    """Main menu bar application."""

    def init(self):
        self = objc.super(TextEchoApp, self).init()
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
        self.input_device_index = self._find_input_device()

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

        # Check if first run (no config file)
        self._is_first_run = not CONFIG_PATH.exists()
        self._setup_wizard = None

        if self._is_first_run:
            # First run: show wizard first, start input monitor after wizard completes.
            # This avoids TSM threading issues — pynput must not start before or
            # during the wizard (which uses NSTextField that initializes TSM on main thread).
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.5, self, objc.selector(self.showSetupWizard_, signature=b'v@:@'), None, False
            )
        else:
            # Subsequent runs: start input monitor immediately (no wizard/NSTextField conflict)
            NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
                0.5, self, objc.selector(self.delayedStart_, signature=b'v@:@'), None, False
            )

        return self

    def showSetupWizard_(self, timer):
        """Show the first-run setup wizard."""
        def on_wizard_complete():
            # This callback is called if user closes wizard early (X button).
            # The normal flow uses _finish_and_restart which restarts the app.
            self.config = self._load_config()
            logger.info("Setup wizard completed (early close)")

        self._setup_wizard = SetupWizard.alloc().initWithCallback_(on_wizard_complete)
        self._setup_wizard.show()

    def delayedStart_(self, timer):
        """Start input monitoring after app is fully running."""
        logger.info("delayedStart_ called")

        # Check if we have accessibility permission; if not, prompt for it
        try:
            from ApplicationServices import AXIsProcessTrusted
            if not AXIsProcessTrusted():
                logger.warning("Accessibility not granted, prompting...")
                options = {"AXTrustedCheckOptionPrompt": kCFBooleanTrue}
                AXIsProcessTrustedWithOptions(options)
        except Exception as e:
            logger.warning("Could not check accessibility: %s", e)

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

    @objc.python_method
    def _find_input_device(self) -> Optional[int]:
        """Find an input device for audio recording.

        Returns the device index to use, or None to use system default.
        Prefers configured device, then built-in MacBook mic by name.
        """
        configured = self.config.get("input_device")

        # If explicitly configured, use it
        if configured is not None:
            if isinstance(configured, int):
                logger.info("Using configured input device index: %d", configured)
                return configured
            # If it's a string, try to find by name
            if isinstance(configured, str):
                for i in range(self.pyaudio.get_device_count()):
                    info = self.pyaudio.get_device_info_by_index(i)
                    if configured.lower() in info['name'].lower() and info['maxInputChannels'] > 0:
                        logger.info("Using input device by name: [%d] %s", i, info['name'])
                        return i
                logger.warning("Configured input device '%s' not found", configured)

        # Find built-in MacBook mic by name (most reliable)
        for i in range(self.pyaudio.get_device_count()):
            info = self.pyaudio.get_device_info_by_index(i)
            if info['maxInputChannels'] > 0:
                name_lower = info['name'].lower()
                if 'macbook' in name_lower and 'microphone' in name_lower:
                    logger.info("Using built-in microphone: [%d] %s", i, info['name'])
                    return i

        # Fallback to system default
        logger.info("Using system default input device")
        return None

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

        # Uninstall
        uninstall_app_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Uninstall TextEcho...", "uninstallApp:", ""
        )
        uninstall_app_item.setTarget_(self)
        self.menu.addItem_(uninstall_app_item)

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
        logger.info("Starting input monitor with trigger button: %s", trigger_button)

        self.input_monitor = InputMonitor(
            callback=self._handle_input_event,
            trigger_button=trigger_button
        )
        self.input_monitor.start()
        logger.info("Input monitor started")

    def _handle_input_event(self, event: InputEvent, modifiers: ModifierState, mouse_pos: tuple):
        """Handle input events from the monitor."""
        logger.debug("Input event: %s, modifiers: ctrl=%s, pos=%s", event, modifiers.ctrl, mouse_pos)

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
        device_info = "default"
        if self.input_device_index is not None:
            try:
                info = self.pyaudio.get_device_info_by_index(self.input_device_index)
                device_info = f"[{self.input_device_index}] {info['name']}"
            except Exception:
                device_info = f"[{self.input_device_index}]"
        logger.info("Recording started (llm=%s, trigger=%s, device=%s)", llm_mode, trigger, device_info)

    def _record_audio(self):
        """Record audio in background thread using PyAudio."""
        stream = None
        try:
            open_kwargs = {
                "format": pyaudio.paInt16,
                "channels": self.channels,
                "rate": self.sample_rate,
                "input": True,
                "frames_per_buffer": self.chunk_size,
            }
            if self.input_device_index is not None:
                open_kwargs["input_device_index"] = self.input_device_index
            stream = self.pyaudio.open(**open_kwargs)

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
                    suffix=".wav", prefix="textecho_", delete=False
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
        socket_path = self.config.get("transcription_socket", "/tmp/textecho_transcription.sock")
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
        socket_path = self.config.get("llm_socket", "/tmp/textecho_llm.sock")

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

    def uninstallApp_(self, sender):
        """Uninstall TextEcho completely."""
        from AppKit import NSAlert, NSAlertStyleWarning, NSAlertFirstButtonReturn

        # Show confirmation dialog
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Uninstall TextEcho?")
        alert.setInformativeText_(
            "This will:\n"
            "• Stop all running processes\n"
            "• Remove auto-start services\n"
            "• Delete the app from Applications\n"
            "• Remove configuration files\n\n"
            "You'll need to manually remove permissions in\n"
            "System Settings → Privacy & Security."
        )
        alert.setAlertStyle_(NSAlertStyleWarning)
        alert.addButtonWithTitle_("Uninstall")
        alert.addButtonWithTitle_("Cancel")

        response = alert.runModal()
        if response != NSAlertFirstButtonReturn:
            return

        logger.info("Starting uninstall...")

        # Stop daemons
        daemon_manager.stop_all_daemons()

        # Remove launchd services
        home = Path.home()
        for plist in ["com.textecho.app.plist", "com.textecho.transcription.plist", "com.textecho.llm.plist"]:
            plist_path = home / "Library" / "LaunchAgents" / plist
            if plist_path.exists():
                subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist_path)],
                             capture_output=True)
                plist_path.unlink()
                logger.info("Removed %s", plist)

        # Remove config and log files
        for f in [".textecho_config", ".textecho_app.log", ".textecho_transcription.log",
                  ".textecho_llm.log", ".textecho_app.pid", ".textecho_transcription.pid",
                  ".textecho_llm.pid"]:
            p = home / f
            if p.exists():
                p.unlink()

        # Remove log directory
        log_dir = home / "Library" / "Logs" / "TextEcho"
        if log_dir.exists():
            import shutil
            shutil.rmtree(log_dir, ignore_errors=True)

        # Remove sockets
        for sock in ["/tmp/textecho_transcription.sock", "/tmp/textecho_llm.sock"]:
            if os.path.exists(sock):
                os.unlink(sock)

        # Open Privacy settings so user can remove permissions
        url = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        NSWorkspace.sharedWorkspace().openURL_(AppKit.NSURL.URLWithString_(url))

        # Schedule app deletion and quit
        app_path = "/Applications/TextEcho.app"
        if os.path.exists(app_path):
            # Use subprocess to delete after we quit
            subprocess.Popen(
                ["bash", "-c", f"sleep 2 && rm -rf '{app_path}'"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )

        # Show completion message
        complete_alert = NSAlert.alloc().init()
        complete_alert.setMessageText_("Uninstall Complete")
        complete_alert.setInformativeText_(
            "TextEcho has been removed.\n\n"
            "Please manually remove TextEcho from:\n"
            "• Accessibility\n"
            "• Input Monitoring\n"
            "• Microphone\n\n"
            "in the Privacy & Security settings that just opened."
        )
        complete_alert.addButtonWithTitle_("OK")
        complete_alert.runModal()

        # Quit
        NSApplication.sharedApplication().terminate_(None)

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
    parser = argparse.ArgumentParser(description="TextEcho")
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
    setup_logging("app", level=logging.DEBUG)

    logger.info("=" * 50)
    logger.info("TextEcho")
    logger.info("=" * 50)

    # On subsequent launches, check accessibility (wizard handles first run)
    if CONFIG_PATH.exists():
        _check_first_run()

    # Create application
    app = NSApplication.sharedApplication()

    # Set as accessory app (no dock icon)
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    # Create our delegate
    delegate = TextEchoApp.alloc().init()
    app.setDelegate_(delegate)

    logger.info("Running... (Cmd+Q or menu to quit)")

    # Run the app
    app.run()


if __name__ == "__main__":
    main()
