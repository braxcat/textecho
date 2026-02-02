"""
py2app build configuration for Dictation-Mac.

Usage:
    python setup.py py2app

This produces dist/Dictation.app — a standalone macOS application bundle.
"""

import os
import sys
from pathlib import Path

# Increase recursion limit — modulegraph's AST visitor hits the default 1000
# when scanning deep dependency trees (MLX, torch, numpy).
sys.setrecursionlimit(5000)

# py2app rejects install_requires, but setuptools auto-populates it from
# pyproject.toml [project.dependencies]. Patch py2app's check to skip it.
import py2app.build_app as _build_app
_orig_finalize = _build_app.py2app.finalize_options

def _patched_finalize(self):
    self.distribution.install_requires = []
    _orig_finalize(self)

_build_app.py2app.finalize_options = _patched_finalize

from setuptools import setup

APP = ["dictation_app_mac.py"]

# Data files to include in the bundle
DATA_FILES = []

# Include DictationOverlay helper binary if it exists
overlay_helper = Path("DictationOverlay/DictationOverlayHelper")
if overlay_helper.exists():
    DATA_FILES.append(("DictationOverlay", ["DictationOverlay/DictationOverlayHelper"]))

# Icon path
ICON_FILE = "assets/DictationMac.icns"
if not os.path.exists(ICON_FILE):
    ICON_FILE = None

OPTIONS = {
    "argv_emulation": False,
    "iconfile": ICON_FILE,
    "plist": {
        "CFBundleName": "Dictation",
        "CFBundleDisplayName": "Dictation",
        "CFBundleIdentifier": "com.braxcat.dictation-mac",
        "CFBundleVersion": "0.1.0",
        "CFBundleShortVersionString": "0.1.0",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,  # Menu bar app, no dock icon
        "NSMicrophoneUsageDescription": (
            "Dictation needs microphone access to record audio for speech-to-text transcription."
        ),
        "NSAppleEventsUsageDescription": (
            "Dictation needs automation access to paste transcribed text into applications."
        ),
    },
    "packages": [
        "lightning_whisper_mlx",
        "numpy",
        "pynput",
        "objc",
        "AppKit",
        "Foundation",
        "Quartz",
        "ApplicationServices",
        "CoreFoundation",
        "_soundfile_data",  # Must be a package (not zipped) so dylib can be loaded
    ],
    "includes": [
        "transcription_daemon_mlx",
        "llm_daemon",
        "input_monitor_mac",
        "text_injector_mac",
        "overlay_swift",
        "daemon_manager",
        "log_config",
        "soundfile",
        # mlx is a namespace package — py2app can't handle it as a "package".
        # We include what the scanner finds; build_app.sh copies the rest
        # (native libs, missing .py modules) as a post-build step.
        "mlx",
        "mlx._reprlib_fix",
        "mlx.extension",
        "mlx.core",
        "mlx.nn",
        "mlx.optimizers",
        "mlx.utils",
    ],
    "excludes": [
        "tkinter",
        "ensurepip",
        "idlelib",
        "lib2to3",
        # Prevent pulling in torch/sympy (not needed at runtime)
        # scipy.signal IS needed by lightning_whisper_mlx timing
        "torch",
        "sympy",
        "IPython",
        "jupyter",
        "matplotlib",
        "PIL",
        "cv2",
    ],
    "frameworks": [],
    "resources": [],
}

# Include libportaudio if it exists (required by PyAudio)
PORTAUDIO_PATHS = [
    "/opt/homebrew/lib/libportaudio.dylib",
    "/usr/local/lib/libportaudio.dylib",
]
for pa_path in PORTAUDIO_PATHS:
    if os.path.exists(pa_path):
        OPTIONS["frameworks"].append(pa_path)
        break

# Include libsndfile from the soundfile package's bundled data.
# soundfile.py is zipped by py2app so it can't find _soundfile_data's dylib
# at runtime. Putting it in Frameworks makes it loadable via dlopen fallback.
_sndfile_data = Path(sys.prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages" / "_soundfile_data"
for _sndfile_name in ["libsndfile_arm64.dylib", "libsndfile.dylib"]:
    _sndfile_path = _sndfile_data / _sndfile_name
    if _sndfile_path.exists():
        OPTIONS["frameworks"].append(str(_sndfile_path))
        break

setup(
    name="Dictation",
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    install_requires=[],
    setup_requires=["py2app"],
)
