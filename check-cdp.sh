#!/bin/bash
# CDP health check for VS Code: on Linux
# Verifies argv.json and CDP endpoint availability

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ARGV_PATH="$HOME/.vscode/argv.json"
CDP_PORT=9222

# Check argv.json
check_argv() {
    if [ ! -f "$ARGV_PATH" ]; then
        echo -e "${RED}FAIL${NC}: $ARGV_PATH not found"
        return 1
    fi

    if grep -q '"remote-debugging-port"' "$ARGV_PATH"; then
        PORT=$(grep -oP '"remote-debugging-port"\s*:\s*"\K[0-9]+' "$ARGV_PATH" || echo "9222")
        echo -e "${GREEN}OK${NC}: argv.json has remote-debugging-port=$PORT"
        CDP_PORT=$PORT
    else
        echo -e "${RED}FAIL${NC}: argv.json missing remote-debugging-port"
        return 1
    fi
}

# Check CDP endpoint
check_cdp() {
    if curl -s "http://127.0.0.1:$CDP_PORT/json" > /dev/null 2>&1; then
        TARGETS=$(curl -s "http://127.0.0.1:$CDP_PORT/json" 2>/dev/null | grep -c '"type":"page"' || echo "0")
        echo -e "${GREEN}OK${NC}: CDP endpoint responding on port $CDP_PORT ($TARGETS page target(s))"
    else
        echo -e "${YELLOW}WARN${NC}: CDP endpoint not responding on port $CDP_PORT"
        echo "       VS Code: may need to be restarted for argv.json changes to take effect."
        return 1
    fi
}

# Check kdotool
check_kdotool() {
    if [ -x "$HOME/.local/bin/kdotool" ]; then
        echo -e "${GREEN}OK${NC}: kdotool installed at ~/.local/bin/kdotool"
    else
        echo -e "${YELLOW}WARN${NC}: kdotool not found at ~/.local/bin/kdotool"
        echo "       Window management on Wayland may not work. Run: yay -S kdotool"
    fi
}

# Check layout script
check_layout_script() {
    SCRIPT="/home/tope/Projects/OS-Toolkit/Reprompty/VSCodeSidePanelLayout/linux_layout.py"
    if [ -f "$SCRIPT" ]; then
        echo -e "${GREEN}OK${NC}: linux_layout.py found"
    else
        echo -e "${RED}FAIL${NC}: linux_layout.py not found"
        return 1
    fi
}

echo "=== Reprompty CDP Health Check ==="
echo ""
check_argv
check_cdp
check_kdotool
check_layout_script
echo ""
echo "=== Done ==="
