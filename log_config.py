#!/usr/bin/env python3
"""
Centralized logging configuration for TextEcho.

Logs to ~/Library/Logs/TextEcho/ with rotating file handlers.
"""

import logging
import os
import platform
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

LOG_DIR = Path.home() / "Library" / "Logs" / "TextEcho"
MAX_BYTES = 10 * 1024 * 1024  # 10 MB
BACKUP_COUNT = 3


def setup_logging(component: str, level: int = logging.INFO) -> logging.Logger:
    """
    Configure logging for a component.

    Args:
        component: Name used for log file (e.g. "app", "transcription", "llm").
        level: Logging level.

    Returns:
        The root logger, configured with file and stderr handlers.
    """
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = LOG_DIR / f"{component}.log"

    # Configure root logger
    root = logging.getLogger()
    root.setLevel(level)

    # Remove existing handlers to avoid duplicates on re-init
    root.handlers.clear()

    formatter = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # File handler with rotation
    file_handler = RotatingFileHandler(
        log_file,
        maxBytes=MAX_BYTES,
        backupCount=BACKUP_COUNT,
    )
    file_handler.setFormatter(formatter)
    root.addHandler(file_handler)

    # Also log to stderr (visible when running from terminal)
    stderr_handler = logging.StreamHandler(sys.stderr)
    stderr_handler.setFormatter(formatter)
    root.addHandler(stderr_handler)

    # Log startup info
    logger = logging.getLogger(__name__)
    logger.info("=" * 50)
    logger.info("TextEcho %s starting", component)
    logger.info("Python %s", sys.version)
    logger.info("macOS %s", platform.mac_ver()[0])
    logger.info("Frozen: %s", getattr(sys, 'frozen', False))
    logger.info("Executable: %s", sys.executable)
    logger.info("Log file: %s", log_file)
    logger.info("=" * 50)

    return root


def get_log_dir() -> Path:
    """Return the log directory path."""
    return LOG_DIR
