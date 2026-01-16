#!/bin/bash
# Controls the dictation app and transcription daemon
# New simplified architecture: 2 processes instead of 3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCRIPTION_PID_FILE=~/.dictation_transcription.pid
TRANSCRIPTION_LOG_FILE=~/.dictation_transcription.log
LLM_PID_FILE=~/.dictation_llm.pid
LLM_LOG_FILE=~/.dictation_llm.log
APP_PID_FILE=~/.dictation_app.pid
APP_LOG_FILE=~/.dictation_app.log
YDOTOOL_LOG_FILE=~/.ydotool.log
YDOTOOL_SOCKET=/tmp/.ydotool_socket
CONFIG_FILE=~/.dictation_config

# Check if logging is enabled in config
is_logging_enabled() {
    if [ -f "$CONFIG_FILE" ]; then
        # Use python to parse JSON and check logging_enabled (defaults to true if not set)
        python3 -c "import json, sys; config = json.load(open('$CONFIG_FILE')); sys.exit(0 if config.get('logging_enabled', True) else 1)" 2>/dev/null
        return $?
    else
        # No config file, default to logging enabled
        return 0
    fi
}

# Get log destination (either log file or /dev/null)
get_log_file() {
    local log_file="$1"
    if is_logging_enabled; then
        echo "$log_file"
    else
        echo "/dev/null"
    fi
}

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
    LOG_DEST=$(get_log_file "$YDOTOOL_LOG_FILE")
    nohup ydotoold > "$LOG_DEST" 2>&1 &
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
    LOG_DEST=$(get_log_file "$TRANSCRIPTION_LOG_FILE")
    nohup uv run python transcription_daemon.py > "$LOG_DEST" 2>&1 &
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

start_llm_daemon() {
    if [ -f "$LLM_PID_FILE" ]; then
        PID=$(cat "$LLM_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            echo "LLM daemon already running (PID $PID)"
            return 0
        else
            rm -f "$LLM_PID_FILE"
        fi
    fi

    cd "$SCRIPT_DIR"
    echo "Starting LLM daemon..."
    LOG_DEST=$(get_log_file "$LLM_LOG_FILE")
    nohup uv run python llm_daemon.py > "$LOG_DEST" 2>&1 &
    sleep 1

    if [ -f "$LLM_PID_FILE" ]; then
        echo "LLM daemon started (PID $(cat "$LLM_PID_FILE"))"
    else
        echo "Warning: LLM daemon may not have started correctly"
        echo "Check logs: tail -f $LLM_LOG_FILE"
    fi
}

stop_llm_daemon() {
    if [ -f "$LLM_PID_FILE" ]; then
        PID=$(cat "$LLM_PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            kill $PID
            echo "LLM daemon stopped"
        else
            rm -f "$LLM_PID_FILE"
        fi
    else
        pkill -f llm_daemon.py 2>/dev/null && echo "LLM daemon stopped"
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
    LOG_DEST=$(get_log_file "$APP_LOG_FILE")
    GI_TYPELIB_PATH=/usr/local/lib/x86_64-linux-gnu/girepository-1.0 \
    YDOTOOL_SOCKET=/tmp/.ydotool_socket \
    PYTHONUNBUFFERED=1 \
    nohup uv run python dictation_app_gtk.py > "$LOG_DEST" 2>&1 &
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

        # Start LLM daemon
        start_llm_daemon
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

        # Stop LLM daemon
        stop_llm_daemon

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

        echo ""
        echo "=== LLM Daemon ==="
        if [ -f "$LLM_PID_FILE" ]; then
            PID=$(cat "$LLM_PID_FILE")
            if ps -p $PID > /dev/null 2>&1; then
                echo "Running (PID $PID)"

                # Check if socket exists
                if [ -S /tmp/dictation_llm.sock ]; then
                    echo "Socket: /tmp/dictation_llm.sock (active)"
                else
                    echo "Socket: /tmp/dictation_llm.sock (not found)"
                fi
            else
                echo "Not running (stale PID file)"
            fi
        else
            echo "Not running (optional - start with: $0 start-llm)"
        fi
        ;;

    logs)
        echo "Following logs (Ctrl+C to stop)..."
        echo "=== App Log ==="
        tail -f "$APP_LOG_FILE" "$TRANSCRIPTION_LOG_FILE" "$LLM_LOG_FILE" 2>/dev/null
        ;;

    app-logs)
        tail -f "$APP_LOG_FILE"
        ;;

    transcription-logs)
        tail -f "$TRANSCRIPTION_LOG_FILE"
        ;;

    llm-logs)
        tail -f "$LLM_LOG_FILE"
        ;;

    start-llm)
        start_llm_daemon
        ;;

    stop-llm)
        stop_llm_daemon
        ;;

    start-transcription)
        start_transcription_daemon
        ;;

    stop-transcription)
        stop_transcription_daemon
        ;;

    restart-transcription)
        stop_transcription_daemon
        sleep 1
        start_transcription_daemon
        ;;

    restart-llm)
        stop_llm_daemon
        sleep 1
        start_llm_daemon
        ;;

    *)
        echo "Usage: $0 {start|stop|restart|status|logs|app-logs|transcription-logs|llm-logs|start-llm|stop-llm}"
        echo ""
        echo "Commands:"
        echo "  start              - Start all components"
        echo "  stop               - Stop all components"
        echo "  restart            - Restart all components"
        echo "  status             - Show status of all components"
        echo "  logs               - Follow all logs"
        echo "  app-logs           - Follow dictation app logs only"
        echo "  transcription-logs - Follow transcription daemon logs only"
        echo "  llm-logs           - Follow LLM daemon logs only"
        echo "  start-llm          - Start LLM daemon (optional, for AI features)"
        echo "  stop-llm           - Stop LLM daemon"
        echo ""
        echo "Architecture:"
        echo "  1. ydotoold         - Types text into active window"
        echo "  2. transcription    - Keeps Whisper model warm, handles transcription"
        echo "  3. dictation_app    - Monitors mouse button, shows GUI, records audio"
        echo "  4. llm_daemon       - (Optional) Local LLM for processing transcriptions"
        echo ""
        echo "LLM Setup:"
        echo "  1. Install: pip install llama-cpp-python"
        echo "  2. Download a GGUF model (e.g., Phi-3 mini)"
        echo "  3. Set llm_model_path and llm_enabled=true in ~/.dictation_config"
        echo "  4. Start with: $0 start-llm"
        exit 1
        ;;
esac
