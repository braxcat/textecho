#!/usr/bin/env python3
"""
Python-native daemon lifecycle management for Dictation-Mac.

Replaces daemon_control_mac.sh for use inside .app bundles where
shell scripts are unreliable. Manages transcription and LLM daemon
subprocesses, PID files, socket cleanup, and launchd integration.
"""

import atexit
import json
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Daemon types and their configuration
DAEMON_CONFIG = {
    "transcription": {
        "module": "transcription_daemon_mlx",
        "socket": "/tmp/dictation_transcription.sock",
        "pid_file": Path.home() / ".dictation_transcription.pid",
        "launchd_label": "com.dictation.transcription",
    },
    "llm": {
        "module": "llm_daemon",
        "socket": "/tmp/dictation_llm.sock",
        "pid_file": Path.home() / ".dictation_llm.pid",
        "launchd_label": "com.dictation.llm",
    },
}

LAUNCHD_DIR = Path.home() / "Library" / "LaunchAgents"

# Track child processes for cleanup
_child_pids: dict[str, int] = {}
_cleanup_registered = False


def _is_process_alive(pid: int) -> bool:
    """Check if a process with the given PID is still running."""
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def _clean_stale_pid(daemon_type: str) -> None:
    """Remove PID file if the process is no longer running."""
    config = DAEMON_CONFIG[daemon_type]
    pid_file = config["pid_file"]
    if not pid_file.exists():
        return

    try:
        pid = int(pid_file.read_text().strip())
        if not _is_process_alive(pid):
            logger.info("Removing stale PID file for %s (pid %d)", daemon_type, pid)
            pid_file.unlink(missing_ok=True)
    except (ValueError, OSError):
        pid_file.unlink(missing_ok=True)


def _clean_stale_socket(daemon_type: str) -> None:
    """Remove socket file if no process owns it."""
    config = DAEMON_CONFIG[daemon_type]
    socket_path = config["socket"]
    if not os.path.exists(socket_path):
        return

    # If PID file exists and process is alive, socket is valid
    pid_file = config["pid_file"]
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            if _is_process_alive(pid):
                return
        except (ValueError, OSError):
            pass

    # No live process owns this socket — remove it
    logger.info("Removing stale socket: %s", socket_path)
    try:
        os.unlink(socket_path)
    except OSError:
        pass


def _get_executable_path() -> str:
    """Get the path to the current Python executable or frozen app binary."""
    if getattr(sys, 'frozen', False):
        # Running as .app bundle — use the app stub (e.g. Dictation), not
        # the raw python interpreter.  The stub runs __boot__.py which
        # executes dictation_app_mac.py, so CLI args like --daemon land
        # in sys.argv correctly.
        macos_dir = Path(sys.executable).parent
        # The stub has the bundle name (no extension).  Find it by
        # picking the executable that is NOT "python*".
        for candidate in macos_dir.iterdir():
            if candidate.is_file() and not candidate.name.startswith("python"):
                return str(candidate)
        # Fallback — shouldn't happen
        return sys.executable
    else:
        # Running from source — use the same Python interpreter
        return sys.executable


def _get_module_path(module_name: str) -> Path:
    """Get the path to a daemon module file."""
    if getattr(sys, 'frozen', False):
        # Inside .app bundle, modules are in Resources
        bundle_dir = Path(sys.executable).parent.parent / "Resources"
        # Try direct path first
        module_path = bundle_dir / f"{module_name}.py"
        if module_path.exists():
            return module_path
        # Also check lib directory
        for candidate in bundle_dir.rglob(f"{module_name}.py"):
            return candidate
    else:
        # Running from source
        script_dir = Path(__file__).parent
        return script_dir / f"{module_name}.py"

    return Path(f"{module_name}.py")


def start_daemon(daemon_type: str) -> bool:
    """
    Start a daemon subprocess.

    Args:
        daemon_type: "transcription" or "llm"

    Returns:
        True if daemon was started successfully.
    """
    if daemon_type not in DAEMON_CONFIG:
        logger.error("Unknown daemon type: %s", daemon_type)
        return False

    config = DAEMON_CONFIG[daemon_type]

    # Clean up stale state
    _clean_stale_pid(daemon_type)
    _clean_stale_socket(daemon_type)

    # Check if already running
    if check_daemon(daemon_type):
        logger.info("%s daemon already running", daemon_type)
        return True

    executable = _get_executable_path()

    if getattr(sys, 'frozen', False):
        # .app bundle: run ourselves with --daemon flag
        cmd = [executable, "--daemon", daemon_type]
    else:
        # Source: run the module directly
        module_path = _get_module_path(config["module"])
        cmd = [executable, str(module_path)]

    # Set up log file path
    log_dir = Path.home() / "Library" / "Logs" / "Dictation"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"{daemon_type}.log"

    # Build environment for the child process.  When running from a .app
    # bundle the PATH is minimal (no Homebrew, no user shell config).
    # Fix up PATH and DYLD_FALLBACK_LIBRARY_PATH for the daemon.
    env = os.environ.copy()
    if getattr(sys, 'frozen', False):
        frameworks_dir = str(Path(sys.executable).parent.parent / "Frameworks")
        existing = env.get('DYLD_FALLBACK_LIBRARY_PATH', '')
        env['DYLD_FALLBACK_LIBRARY_PATH'] = (
            frameworks_dir + (':' + existing if existing else '')
        )
        # Ensure Homebrew bin dirs are on PATH (needed for ffmpeg etc.)
        path = env.get('PATH', '/usr/bin:/bin')
        for brew_dir in ['/opt/homebrew/bin', '/usr/local/bin']:
            if brew_dir not in path:
                path = brew_dir + ':' + path
        env['PATH'] = path

    try:
        with open(log_file, "a") as log_f:
            proc = subprocess.Popen(
                cmd,
                stdout=log_f,
                stderr=subprocess.STDOUT,
                start_new_session=True,  # Detach from parent process group
                env=env,
            )

        _child_pids[daemon_type] = proc.pid
        _ensure_cleanup_registered()

        logger.info("Started %s daemon (PID: %d)", daemon_type, proc.pid)

        # Wait briefly for socket to appear
        socket_path = config["socket"]
        for _ in range(20):
            time.sleep(0.25)
            if os.path.exists(socket_path):
                return True
            # Check if process died immediately
            if not _is_process_alive(proc.pid):
                logger.error("%s daemon exited immediately", daemon_type)
                return False

        # Process is alive but socket didn't appear yet — might still be loading model
        if _is_process_alive(proc.pid):
            logger.warning(
                "%s daemon started but socket not yet available (model may be loading)",
                daemon_type,
            )
            return True

        return False

    except Exception as e:
        logger.error("Failed to start %s daemon: %s", daemon_type, e)
        return False


def stop_daemon(daemon_type: str, timeout: float = 5.0) -> bool:
    """
    Stop a daemon process.

    Sends SIGTERM first, waits for graceful shutdown, then SIGKILL if needed.

    Args:
        daemon_type: "transcription" or "llm"
        timeout: Seconds to wait for graceful shutdown before SIGKILL.

    Returns:
        True if daemon was stopped (or was already stopped).
    """
    if daemon_type not in DAEMON_CONFIG:
        logger.error("Unknown daemon type: %s", daemon_type)
        return False

    config = DAEMON_CONFIG[daemon_type]
    pid_file = config["pid_file"]
    pid = None

    # Get PID from file or tracked children
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
        except (ValueError, OSError):
            pass

    if pid is None:
        pid = _child_pids.get(daemon_type)

    if pid is None or not _is_process_alive(pid):
        # Already stopped — clean up
        pid_file.unlink(missing_ok=True)
        _child_pids.pop(daemon_type, None)
        _clean_stale_socket(daemon_type)
        return True

    # Send SIGTERM
    logger.info("Stopping %s daemon (PID: %d)...", daemon_type, pid)
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

    # Wait for graceful exit
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _is_process_alive(pid):
            break
        time.sleep(0.2)
    else:
        # Process didn't exit — force kill
        logger.warning("Force-killing %s daemon (PID: %d)", daemon_type, pid)
        try:
            os.kill(pid, signal.SIGKILL)
            time.sleep(0.5)
        except OSError:
            pass

    # Clean up
    pid_file.unlink(missing_ok=True)
    _child_pids.pop(daemon_type, None)
    _clean_stale_socket(daemon_type)

    logger.info("%s daemon stopped", daemon_type)
    return True


def stop_all_daemons() -> None:
    """Stop all known daemons. Called on app quit."""
    for daemon_type in DAEMON_CONFIG:
        try:
            stop_daemon(daemon_type)
        except Exception as e:
            logger.error("Error stopping %s: %s", daemon_type, e)


def check_daemon(daemon_type: str) -> bool:
    """
    Check if a daemon is running.

    Validates PID file against actual process and cleans up stale state.

    Returns:
        True if daemon process is alive.
    """
    if daemon_type not in DAEMON_CONFIG:
        return False

    config = DAEMON_CONFIG[daemon_type]
    pid_file = config["pid_file"]

    if not pid_file.exists():
        # Check tracked children
        pid = _child_pids.get(daemon_type)
        if pid and _is_process_alive(pid):
            return True
        return False

    try:
        pid = int(pid_file.read_text().strip())
    except (ValueError, OSError):
        pid_file.unlink(missing_ok=True)
        return False

    if _is_process_alive(pid):
        return True

    # Process is dead — clean up
    pid_file.unlink(missing_ok=True)
    _clean_stale_socket(daemon_type)
    return False


def install_launchd(app_path: Optional[str] = None) -> bool:
    """
    Generate and install launchd plist files for auto-start.

    Args:
        app_path: Path to the .app bundle. If None, uses current executable.

    Returns:
        True if installation succeeded.
    """
    LAUNCHD_DIR.mkdir(parents=True, exist_ok=True)

    if app_path is None:
        if getattr(sys, 'frozen', False):
            # Inside .app: go up to the .app directory
            app_path = str(Path(sys.executable).parent.parent.parent)
        else:
            app_path = str(Path(__file__).parent)

    executable = _get_executable_path()

    for daemon_type, config in DAEMON_CONFIG.items():
        label = config["launchd_label"]
        log_dir = Path.home() / "Library" / "Logs" / "Dictation"

        if getattr(sys, 'frozen', False):
            # .app bundle: use the app binary with --daemon flag
            program_args = [
                f"{app_path}/Contents/MacOS/Dictation",
                "--daemon",
                daemon_type,
            ]
        else:
            # Source: use python + module
            module_path = _get_module_path(config["module"])
            program_args = [executable, str(module_path)]

        plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        {"".join(f"        <string>{arg}</string>{chr(10)}" for arg in program_args)}    </array>
    <key>RunAtLoad</key>
    <{"true" if daemon_type == "transcription" else "false"}/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>{log_dir}/{daemon_type}.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/{daemon_type}.log</string>
</dict>
</plist>
"""
        plist_path = LAUNCHD_DIR / f"{label}.plist"
        try:
            plist_path.write_text(plist_content)
            logger.info("Installed launchd plist: %s", plist_path)
        except OSError as e:
            logger.error("Failed to write plist %s: %s", plist_path, e)
            return False

    # Also install the main app plist
    app_label = "com.dictation.app"
    log_dir = Path.home() / "Library" / "Logs" / "Dictation"

    if getattr(sys, 'frozen', False):
        app_program_args = [f"{app_path}/Contents/MacOS/Dictation"]
    else:
        app_program_args = [executable, str(Path(__file__).parent / "dictation_app_mac.py")]

    app_plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{app_label}</string>
    <key>ProgramArguments</key>
    <array>
        {"".join(f"        <string>{arg}</string>{chr(10)}" for arg in app_program_args)}    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>{log_dir}/app.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/app.log</string>
</dict>
</plist>
"""
    app_plist_path = LAUNCHD_DIR / f"{app_label}.plist"
    try:
        app_plist_path.write_text(app_plist)
        logger.info("Installed launchd plist: %s", app_plist_path)
    except OSError as e:
        logger.error("Failed to write plist %s: %s", app_plist_path, e)
        return False

    logger.info("Launchd services installed successfully")
    return True


def uninstall_launchd() -> bool:
    """Remove launchd plist files."""
    labels = [
        "com.dictation.app",
        "com.dictation.transcription",
        "com.dictation.llm",
    ]

    for label in labels:
        plist_path = LAUNCHD_DIR / f"{label}.plist"
        if plist_path.exists():
            # Unload first
            subprocess.run(
                ["launchctl", "unload", str(plist_path)],
                capture_output=True,
            )
            plist_path.unlink()
            logger.info("Removed launchd plist: %s", label)

    logger.info("Launchd services uninstalled")
    return True


def _cleanup_on_exit():
    """Cleanup handler called on app exit."""
    logger.info("Cleaning up child daemons on exit...")
    stop_all_daemons()


def _signal_handler(signum, frame):
    """Handle SIGTERM/SIGINT for graceful shutdown."""
    logger.info("Received signal %d, shutting down...", signum)
    stop_all_daemons()
    sys.exit(0)


def _ensure_cleanup_registered():
    """Register cleanup handlers (only once)."""
    global _cleanup_registered
    if _cleanup_registered:
        return
    _cleanup_registered = True

    atexit.register(_cleanup_on_exit)
    signal.signal(signal.SIGTERM, _signal_handler)
    signal.signal(signal.SIGINT, _signal_handler)
