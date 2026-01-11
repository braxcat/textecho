#!/bin/bash
# Controls the transcription daemon and ydotool daemon for the dictation app

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCRIPTION_PID_FILE=~/.dictation_transcription.pid
TRANSCRIPTION_LOG_FILE=~/.dictation_transcription.log
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

case "$1" in
    start)
        # Start ydotoold first
        start_ydotoold

        # Start transcription daemon
        if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
            PID=$(cat "$TRANSCRIPTION_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Transcription daemon already running (PID $PID)"
                exit 0
            fi
        fi

        cd "$SCRIPT_DIR"
        echo "Starting transcription daemon..."
        nohup uv run python transcription_daemon.py > "$TRANSCRIPTION_LOG_FILE" 2>&1 &
        sleep 1

        if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
            PID=$(cat "$TRANSCRIPTION_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Transcription daemon started (PID $PID)"
            else
                echo "Failed to start daemon - check $TRANSCRIPTION_LOG_FILE"
                exit 1
            fi
        else
            echo "Failed to start daemon - no PID file created"
            exit 1
        fi
        ;;

    stop)
        # Stop transcription daemon
        if [ -f "$TRANSCRIPTION_PID_FILE" ]; then
            PID=$(cat "$TRANSCRIPTION_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                kill $PID
                echo "Transcription daemon stopped"
            else
                echo "Daemon not running (stale PID file)"
                rm -f "$TRANSCRIPTION_PID_FILE"
            fi
        else
            # Try to kill by process name as fallback
            if pkill -f transcription_daemon.py; then
                echo "Transcription daemon stopped"
            else
                echo "Transcription daemon not running"
            fi
        fi

        # Stop ydotoold
        stop_ydotoold
        ;;

    restart)
        $0 stop
        sleep 1
        $0 start
        ;;

    status)
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

                # Show last few log lines
                if [ -f "$TRANSCRIPTION_LOG_FILE" ]; then
                    echo ""
                    echo "Recent logs:"
                    tail -n 5 "$TRANSCRIPTION_LOG_FILE"
                fi
            else
                echo "Not running (stale PID file)"
            fi
        else
            echo "Not running"
        fi
        ;;

    logs)
        if [ -f "$TRANSCRIPTION_LOG_FILE" ]; then
            tail -f "$TRANSCRIPTION_LOG_FILE"
        else
            echo "No log file found at $TRANSCRIPTION_LOG_FILE"
        fi
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        echo ""
        echo "Commands:"
        echo "  start   - Start ydotoold and transcription daemon"
        echo "  stop    - Stop all daemons"
        echo "  restart - Restart all daemons"
        echo "  status  - Show daemon status and recent logs"
        echo "  logs    - Follow transcription daemon logs in real-time"
        exit 1
        ;;
esac
