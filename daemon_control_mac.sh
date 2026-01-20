#!/bin/bash
#
# Daemon Control Script for Dictation-Mac (macOS launchd version)
#
# Usage:
#   ./daemon_control_mac.sh install    - Install launchd services (auto-start on login)
#   ./daemon_control_mac.sh uninstall  - Remove launchd services
#   ./daemon_control_mac.sh start      - Start all daemons
#   ./daemon_control_mac.sh stop       - Stop all daemons
#   ./daemon_control_mac.sh restart    - Restart all daemons
#   ./daemon_control_mac.sh status     - Show daemon status
#   ./daemon_control_mac.sh logs       - Show recent logs
#

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAUNCHD_DIR="$SCRIPT_DIR/launchd"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

# Service names
APP_SERVICE="com.dictation.app"
TRANSCRIPTION_SERVICE="com.dictation.transcription"
LLM_SERVICE="com.dictation.llm"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Install plist files to ~/Library/LaunchAgents
install_services() {
    print_status "Installing launchd services..."

    mkdir -p "$LAUNCH_AGENTS_DIR"

    # Process menu bar app plist
    print_status "Installing menu bar app..."
    sed -e "s|__WORKING_DIR__|$SCRIPT_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        "$LAUNCHD_DIR/$APP_SERVICE.plist" > "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist"
    print_success "Installed $APP_SERVICE"

    # Process transcription plist
    print_status "Installing transcription daemon..."
    sed -e "s|__WORKING_DIR__|$SCRIPT_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        "$LAUNCHD_DIR/$TRANSCRIPTION_SERVICE.plist" > "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist"
    print_success "Installed $TRANSCRIPTION_SERVICE"

    # Process LLM plist
    print_status "Installing LLM daemon..."
    sed -e "s|__WORKING_DIR__|$SCRIPT_DIR|g" \
        -e "s|__HOME__|$HOME|g" \
        "$LAUNCHD_DIR/$LLM_SERVICE.plist" > "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist"
    print_success "Installed $LLM_SERVICE (disabled by default)"

    print_success "Installation complete!"
    echo ""
    echo "To start everything now, run:"
    echo "  $0 start"
    echo ""
    echo "Everything will auto-start on login."
    echo "To enable LLM daemon, edit ~/.dictation_config and set llm_enabled: true"
}

# Uninstall plist files
uninstall_services() {
    print_status "Uninstalling launchd services..."

    # Stop services first
    stop_services 2>/dev/null || true

    # Remove plist files
    if [ -f "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" ]; then
        launchctl unload "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" 2>/dev/null || true
        rm "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist"
        print_success "Removed $APP_SERVICE"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist" ]; then
        rm "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist"
        print_success "Removed $TRANSCRIPTION_SERVICE"
    fi

    if [ -f "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist" ]; then
        rm "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist"
        print_success "Removed $LLM_SERVICE"
    fi

    print_success "Uninstallation complete!"
}

# Start services
start_services() {
    print_status "Starting services..."

    # Start transcription daemon first (app depends on it)
    if pgrep -f "transcription_daemon_mlx.py" > /dev/null; then
        print_warning "Transcription daemon already running"
    elif [ -f "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist" ]; then
        launchctl load "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist" 2>/dev/null || true
        launchctl start "$TRANSCRIPTION_SERVICE" 2>/dev/null || true
        print_success "Started transcription daemon (via launchd)"
    else
        # Direct execution fallback
        print_status "Starting transcription daemon directly..."
        nohup "$SCRIPT_DIR/.venv/bin/python3" -u "$SCRIPT_DIR/transcription_daemon_mlx.py" >> "$HOME/.dictation_transcription.log" 2>&1 &
        sleep 1
        if pgrep -f "transcription_daemon_mlx.py" > /dev/null; then
            print_success "Started transcription daemon (PID: $!)"
        else
            print_error "Failed to start transcription daemon"
        fi
    fi

    # Check if LLM is enabled in config
    if [ -f "$HOME/.dictation_config" ]; then
        LLM_ENABLED=$(python3 -c "import json; print(json.load(open('$HOME/.dictation_config')).get('llm_enabled', False))" 2>/dev/null || echo "False")
        if [ "$LLM_ENABLED" = "True" ]; then
            if [ -f "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist" ]; then
                launchctl load "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist" 2>/dev/null || true
                launchctl start "$LLM_SERVICE" 2>/dev/null || true
                print_success "Started LLM daemon (via launchd)"
            else
                # Direct execution fallback
                if pgrep -f "llm_daemon.py" > /dev/null; then
                    print_warning "LLM daemon already running"
                else
                    print_status "Starting LLM daemon directly..."
                    cd "$SCRIPT_DIR"
                    nohup python3 -u llm_daemon.py >> "$HOME/.dictation_llm.log" 2>&1 &
                    sleep 1
                    if pgrep -f "llm_daemon.py" > /dev/null; then
                        print_success "Started LLM daemon (PID: $!)"
                    else
                        print_error "Failed to start LLM daemon"
                    fi
                fi
            fi
        else
            print_warning "LLM daemon disabled (set llm_enabled: true in ~/.dictation_config to enable)"
        fi
    fi

    # Start menu bar app (check if already running first)
    if pgrep -f "dictation_app_mac.py" > /dev/null; then
        print_warning "Menu bar app already running"
    elif [ -f "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" ]; then
        launchctl load "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" 2>/dev/null || true
        launchctl start "$APP_SERVICE" 2>/dev/null || true
        print_success "Started menu bar app (via launchd)"
    else
        # Direct execution fallback
        print_status "Starting menu bar app directly..."
        cd "$SCRIPT_DIR"
        nohup "$SCRIPT_DIR/.venv/bin/python3" -u "$SCRIPT_DIR/dictation_app_mac.py" >> "$HOME/.dictation_app.log" 2>&1 &
        sleep 1
        if pgrep -f "dictation_app_mac.py" > /dev/null; then
            print_success "Started menu bar app"
        else
            print_error "Failed to start menu bar app"
        fi
    fi
}

# Stop services
stop_services() {
    print_status "Stopping services..."

    # Stop menu bar app first
    launchctl stop "$APP_SERVICE" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" 2>/dev/null || true
    pkill -f "dictation_app_mac.py" 2>/dev/null || true
    pkill -f "DictationOverlayHelper" 2>/dev/null || true
    print_success "Stopped menu bar app"

    # Stop transcription daemon
    launchctl stop "$TRANSCRIPTION_SERVICE" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist" 2>/dev/null || true
    pkill -f "transcription_daemon_mlx.py" 2>/dev/null || true
    print_success "Stopped transcription daemon"

    # Stop LLM daemon
    launchctl stop "$LLM_SERVICE" 2>/dev/null || true
    launchctl unload "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist" 2>/dev/null || true
    pkill -f "llm_daemon.py" 2>/dev/null || true
    print_success "Stopped LLM daemon"

    # Clean up socket files
    rm -f /tmp/dictation_transcription.sock 2>/dev/null || true
    rm -f /tmp/dictation_llm.sock 2>/dev/null || true
}

# Restart services
restart_services() {
    stop_services
    sleep 1
    start_services
}

# Show status
show_status() {
    print_status "Service Status:"
    echo ""

    # Check menu bar app
    APP_PID=$(pgrep -f "dictation_app_mac.py" 2>/dev/null || true)
    if [ -n "$APP_PID" ]; then
        print_success "Menu bar app: ${GREEN}running${NC} (PID: $APP_PID)"
    else
        print_error "Menu bar app: ${RED}not running${NC}"
    fi

    # Check transcription daemon (launchd or direct)
    TRANS_PID=$(pgrep -f "transcription_daemon_mlx.py" 2>/dev/null || true)
    if [ -n "$TRANS_PID" ]; then
        print_success "Transcription daemon: ${GREEN}running${NC} (PID: $TRANS_PID)"
    else
        print_error "Transcription daemon: ${RED}not running${NC}"
    fi

    # Check LLM daemon (launchd or direct)
    LLM_PID=$(pgrep -f "llm_daemon.py" 2>/dev/null || true)
    if [ -n "$LLM_PID" ]; then
        print_success "LLM daemon: ${GREEN}running${NC} (PID: $LLM_PID)"
    else
        # Check if LLM is even enabled
        if [ -f "$HOME/.dictation_config" ]; then
            LLM_ENABLED=$(python3 -c "import json; print(json.load(open('$HOME/.dictation_config')).get('llm_enabled', False))" 2>/dev/null || echo "False")
            if [ "$LLM_ENABLED" = "True" ]; then
                print_error "LLM daemon: ${RED}not running${NC}"
            else
                print_warning "LLM daemon: ${YELLOW}disabled${NC}"
            fi
        else
            print_warning "LLM daemon: ${YELLOW}disabled${NC}"
        fi
    fi

    # Check socket files
    echo ""
    print_status "Socket files:"
    if [ -S "/tmp/dictation_transcription.sock" ]; then
        print_success "Transcription socket: exists"
    else
        print_warning "Transcription socket: not found"
    fi

    if [ -S "/tmp/dictation_llm.sock" ]; then
        print_success "LLM socket: exists"
    else
        print_warning "LLM socket: not found"
    fi

    # Show launchd installation status
    echo ""
    print_status "Auto-start (launchd):"
    if [ -f "$LAUNCH_AGENTS_DIR/$APP_SERVICE.plist" ]; then
        print_success "Menu bar app: installed"
    else
        print_warning "Menu bar app: not installed"
    fi
    if [ -f "$LAUNCH_AGENTS_DIR/$TRANSCRIPTION_SERVICE.plist" ]; then
        print_success "Transcription: installed"
    else
        print_warning "Transcription: not installed"
    fi
    if [ -f "$LAUNCH_AGENTS_DIR/$LLM_SERVICE.plist" ]; then
        print_success "LLM: installed"
    else
        print_warning "LLM: not installed"
    fi
}

# Show logs
show_logs() {
    print_status "Recent logs:"
    echo ""

    echo -e "${BLUE}=== Transcription Daemon ===${NC}"
    if [ -f "$HOME/.dictation_transcription.log" ]; then
        tail -20 "$HOME/.dictation_transcription.log"
    else
        echo "(no log file)"
    fi

    echo ""
    echo -e "${BLUE}=== LLM Daemon ===${NC}"
    if [ -f "$HOME/.dictation_llm.log" ]; then
        tail -20 "$HOME/.dictation_llm.log"
    else
        echo "(no log file)"
    fi
}

# Main
case "${1:-}" in
    install)
        install_services
        ;;
    uninstall)
        uninstall_services
        ;;
    start)
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        restart_services
        ;;
    status)
        show_status
        ;;
    logs)
        show_logs
        ;;
    *)
        echo "Dictation-Mac Daemon Control (launchd)"
        echo ""
        echo "Usage: $0 {install|uninstall|start|stop|restart|status|logs}"
        echo ""
        echo "Commands:"
        echo "  install    - Install launchd services (auto-start on login)"
        echo "  uninstall  - Remove launchd services"
        echo "  start      - Start all daemons"
        echo "  stop       - Stop all daemons"
        echo "  restart    - Restart all daemons"
        echo "  status     - Show daemon status"
        echo "  logs       - Show recent logs"
        exit 1
        ;;
esac
