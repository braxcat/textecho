#!/bin/bash
# Controls the dictation app and transcription daemon
# New simplified architecture: 2 processes instead of 3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCRIPTION_PID_FILE=~/.dictation_transcription.pid
TRANSCRIPTION_LOG_FILE=~/.dictation_transcription.log
APP_PID_FILE=~/.dictation_app.pid
APP_LOG_FILE=~/.dictation_app.log
YDOTOOL_LOG_FILE=~/.ydotool.log
YDOTOOL_SOCKET=/tmp/.ydotool_socket

start_ydotoold() {
    # Check if ydotoold is already running
    if pgrep -x ydotoold > /dev/null 2>&1; then
        echo "ydotoold already running"
        return 0
    fi

    # Check if ydotoold is installed
    if ! command -v ydotoold &> /dev/null; then
        echo "Warning: ydotoold not found. Text typing will not work."
        echo "Install with: sudo apt install ydotool"
        return 1
    fi

    echo "Starting ydotoold..."
    nohup ydotoold > "$YDOTOOL_LOG_FILE" 2>&1 &
    sleep 0.5

    if pgrep -x ydotoold > /dev/null 2>&1; then
        echo "ydotoold started (PID $(pgrep -x ydotoold))"
        # Wait for socket to be created
        for i in {1..10}; do
            if [ -S "$YDOTOOL_SOCKET" ]; then
                echo "ydotool socket created at $YDOTOOL_SOCKET"
                return 0
            fi
            sleep 0.2
        done
        echo "Warning: ydotool socket not found at $YDOTOOL_SOCKET"
    else
        echo "Failed to start ydotoold"
        return 1
    fi
}

stop_ydotoold() {
    if pgrep -x ydotoold > /dev/null 2>&1; then
        pkill -x ydotoold
        echo "ydotoold stopped"
    fi
}

start_transcription_daemon() {
    if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
        PID=$(cat "$TRANSCRIPTION_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo "Transcription daemon already running (PID $PID)"
            return 0
        else
            rm -f "$TRANSCRIPTION_PID_FILE"
        fi
    fi

    cd "$SCRIPT_DIR"
    echo "Starting transcription daemon..."
    nohup uv run python transcription_daemon.py > "$TRANSCRIPTION_LOG_FILE" 2>&1 &
    sleep 1

    if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
        echo "Transcription daemon started (PID $(cat "$TRANSCRIPTION_PID_FILE"))"
    else
        echo "Warning: Transcription daemon may not have started correctly"
    fi
}

stop_transcription_daemon() {
    if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
        PID=$(cat "$TRANSCRIPTION_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            kill $PID
            echo "Transcription daemon stopped"
        else
            rm -f "$TRANSCRIPTION_PID_FILE"
        fi
    else
        pkill -f transcription_daemon.py 2>/dev/null && echo "Transcription daemon stopped"
    fi
}

start_dictation_app() {
    if [ -f "$APP_PID_FILE" ]; then
        PID=$(cat "$APP_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo "Dictation app already running (PID $PID)"
            return 0
        else
            rm -f "$APP_PID_FILE"
        fi
    fi

    cd "$SCRIPT_DIR"
    echo "Starting dictation app..."
    GI_TYPELIB_PATH=/usr/local/lib/x86_64-linux-gnu/girepository-1.0 \
    YDOTOOL_SOCKET=/tmp/.ydotool_socket \
    PYTHONUNBUFFERED=1 \
    nohup uv run python dictation_app_gtk.py > "$APP_LOG_FILE" 2>&1 &
    sleep 1

    if [ -f "$APP_PID_FILE" ]; then
        echo "Dictation app started (PID $(cat "$APP_PID_FILE"))"
        echo "Press Mouse 4 (side button) to record"
    else
        echo "Warning: Dictation app may not have started correctly"
        echo "Check logs: tail -f $APP_LOG_FILE"
    fi
}

stop_dictation_app() {
    if [ -f "$APP_PID_FILE" ]; then
        PID=$(cat "$APP_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            kill $PID
            echo "Dictation app stopped"
        else
            rm -f "$APP_PID_FILE"
        fi
    else
        pkill -f dictation_app.py 2>/dev/null && echo "Dictation app stopped"
    fi

    # Also kill old daemon/GUI if running
    pkill -f dictation_daemon.py 2>/dev/null
    pkill -f "recorder_gui.py.*--background" 2>/dev/null
}

case "$1" in
    start)
        echo "Starting dictation system..."
        echo ""

        # Start ydotoold first
        start_ydotoold
        echo ""

        # Start transcription daemon
        start_transcription_daemon
        echo ""

        # Start dictation app (unified evdev + GUI)
        start_dictation_app
        echo ""

        echo "Dictation system ready!"
        ;;

    stop)
        echo "Stopping dictation system..."

        # Stop dictation app
        stop_dictation_app

        # Stop transcription daemon
        stop_transcription_daemon

        # Stop ydotoold
        stop_ydotoold

        echo "Dictation system stopped"
        ;;

    restart)
        $0 stop
        sleep 1
        $0 start
        ;;

    status)
        echo "=== Dictation App ==="
        if [ -f "$APP_PID_FILE" ]; then
            PID=$(cat "$APP_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Running (PID $PID)"
                echo "Hotkey: Mouse 4 (side button) - hold to record, release to transcribe"
            else
                echo "Not running (stale PID file)"
            fi
        else
            echo "Not running"
        fi

        echo ""
        echo "=== ydotoold ==="
        if pgrep -x ydotoold > /dev/null 2>&1; then
            echo "Running (PID $(pgrep -x ydotoold))"
            if [ -S "$YDOTOOL_SOCKET" ]; then
                echo "Socket: $YDOTOOL_SOCKET (active)"
            else
                echo "Socket: $YDOTOOL_SOCKET (not found - WARNING)"
            fi
        else
            echo "Not running"
        fi

        echo ""
        echo "=== Transcription Daemon ==="
        if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
            PID=$(cat "$TRANSCRIPTION_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Running (PID $PID)"

                # Check if socket exists
                if [ -S /tmp/dictation_transcription.sock ]; then
                    echo "Socket: /tmp/dictation_transcription.sock (active)"
                else
                    echo "Socket: /tmp/dictation_transcription.sock (not found)"
                fi
            else
                echo "Not running (stale PID file)"
            fi
        else
            echo "Not running"
        fi
        ;;

    logs)
        echo "Following logs (Ctrl+C to stop)..."
        echo "=== App Log ==="
        tail -f "$APP_LOG_FILE" "$TRANSCRIPTION_LOG_FILE" 2>/dev/null
        ;;

    app-logs)
        tail -f "$APP_LOG_FILE"
        ;;

    transcription-logs)
        tail -f "$TRANSCRIPTION_LOG_FILE"
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|logs|app-logs|transcription-logs}"
        echo ""
        echo "Commands:"
        echo "  start              - Start all components"
        echo "  stop               - Stop all components"
        echo "  restart            - Restart all components"
        echo "  status             - Show status of all components"
        echo "  logs               - Follow all logs"
        echo "  app-logs           - Follow dictation app logs only"
        echo "  transcription-logs - Follow transcription daemon logs only"
        echo ""
        echo "Architecture:"
        echo "  1. ydotoold         - Types text into active window"
        echo "  2. transcription    - Keeps Whisper model warm, handles transcription"
        echo "  3. dictation_app    - Monitors mouse button, shows GUI, records audio"
        exit 1
        ;;
esac
