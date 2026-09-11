#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
#  site-setup.sh  —  Temporary Remote Support Script
#  Run this on the ON-SITE Linux PC so your office PC can SSH in.
#
#  Usage:   sudo bash site-setup.sh
#  Cleanup: Press Ctrl+C when done — everything is auto-removed.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config ────────────────────────────────────────────────────
TUNNEL_METHOD="${1:-pinggy}"          # pinggy | ngrok | serveo | bore | tmate
GIVE_SUDO="yes"                    # "yes" = temp user gets sudo
BORE_SERVER="bore.pub"
# ──────────────────────────────────────────────────────────────

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# State tracking for cleanup
TEMP_USER=""
TEMP_PASS=""
TUNNEL_PID=""
SSHD_WAS_RUNNING=""
BORE_BIN=""

# ── Helpers ───────────────────────────────────────────────────
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
banner() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}$1${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Root check ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root.  Try:  sudo bash $0"
    exit 1
fi

# ── Cleanup (runs on EXIT / Ctrl+C) ──────────────────────────
cleanup() {
    echo ""
    banner "CLEANING UP..."

    # Kill tunnel
    if [[ -n "$TUNNEL_PID" ]] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
        kill "$TUNNEL_PID" 2>/dev/null && log "Tunnel stopped."
    fi

    # Remove temp user
    if [[ -n "$TEMP_USER" ]] && id "$TEMP_USER" &>/dev/null; then
        # Remove from sudoers if added
        rm -f "/etc/sudoers.d/$TEMP_USER" 2>/dev/null
        # Kill any remaining processes
        pkill -u "$TEMP_USER" 2>/dev/null || true
        sleep 1
        userdel -r "$TEMP_USER" 2>/dev/null && log "Temp user '$TEMP_USER' removed."
    fi

    # Stop sshd if we started it
    if [[ "$SSHD_WAS_RUNNING" == "no" ]]; then
        systemctl stop sshd 2>/dev/null || systemctl stop ssh 2>/dev/null || true
        log "SSH server stopped (it wasn't running before)."
    fi

    # Remove bore binary if we downloaded it
    if [[ -n "$BORE_BIN" ]] && [[ -f "$BORE_BIN" ]]; then
        rm -f "$BORE_BIN" && log "Bore binary removed."
    fi

    log "All clean. Session ended."
    echo ""
}
trap cleanup EXIT

# ── Detect package manager ────────────────────────────────────
install_pkg() {
    local pkg="$1"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "$pkg"
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg"
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm --quiet "$pkg"
    elif command -v zypper &>/dev/null; then
        zypper install -y "$pkg"
    else
        err "Could not detect package manager. Install '$pkg' manually."
        exit 1
    fi
}

# ══════════════════════════════════════════════════════════════
#  STEP 1: SSH SERVER
# ══════════════════════════════════════════════════════════════
banner "STEP 1: Setting up SSH Server"

# Check if sshd is already running
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    SSHD_WAS_RUNNING="yes"
    log "SSH server is already running."
else
    SSHD_WAS_RUNNING="no"
    warn "SSH server not running. Installing & starting..."

    if ! command -v sshd &>/dev/null; then
        install_pkg openssh-server
    fi

    systemctl start sshd 2>/dev/null || systemctl start ssh 2>/dev/null
    systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null
    log "SSH server started."
fi

# Make sure password auth is enabled for our temp user
SSHD_CONFIG="/etc/ssh/sshd_config"
if grep -qE "^PasswordAuthentication\s+no" "$SSHD_CONFIG" 2>/dev/null; then
    warn "Password auth is disabled. Enabling temporarily..."
    sed -i 's/^PasswordAuthentication\s\+no/PasswordAuthentication yes/' "$SSHD_CONFIG"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
    log "Password authentication enabled."
fi

# ══════════════════════════════════════════════════════════════
#  STEP 2: TEMP USER
# ══════════════════════════════════════════════════════════════
banner "STEP 2: Creating temporary support user"

# Generate random username and password
RAND_SUFFIX=$(head -c 4 /dev/urandom | xxd -p)
TEMP_USER="support_${RAND_SUFFIX}"
TEMP_PASS=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)

# Create user
useradd -m -s /bin/bash "$TEMP_USER"
echo "${TEMP_USER}:${TEMP_PASS}" | chpasswd

log "User created: ${BOLD}${TEMP_USER}${NC}"

# Optionally grant sudo
if [[ "$GIVE_SUDO" == "yes" ]]; then
    echo "$TEMP_USER ALL=(ALL) ALL" > "/etc/sudoers.d/$TEMP_USER"
    chmod 440 "/etc/sudoers.d/$TEMP_USER"
    log "Sudo access granted (requires password)."
fi

# ══════════════════════════════════════════════════════════════
#  STEP 3: TUNNEL
# ══════════════════════════════════════════════════════════════
banner "STEP 3: Opening tunnel ($TUNNEL_METHOD)"

case "$TUNNEL_METHOD" in

# ── PINGGY (default — no download, no signup, uses port 443) ──
pinggy)
    log "Starting SSH reverse tunnel via Pinggy (port 443)..."
    PINGGY_LOG=$(mktemp /tmp/pinggy_log.XXXXXX)

    ssh -p 443 -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R0:localhost:22 tcp@a.pinggy.io > "$PINGGY_LOG" 2>&1 &
    TUNNEL_PID=$!

    TUNNEL_HOST=""
    TUNNEL_PORT=""
    for i in $(seq 1 30); do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            break
        fi
        if [[ -s "$PINGGY_LOG" ]]; then
            # Pinggy outputs: tcp://xxxxx.tcp.pinggy.online:PORT
            FULL_URL=$(grep -oP 'tcp://[^\s]+' "$PINGGY_LOG" | head -1)
            if [[ -n "$FULL_URL" ]]; then
                # Extract host and port from tcp://host:port
                HOSTPORT=$(echo "$FULL_URL" | sed 's|tcp://||')
                TUNNEL_HOST=$(echo "$HOSTPORT" | rev | cut -d: -f2- | rev)
                TUNNEL_PORT=$(echo "$HOSTPORT" | rev | cut -d: -f1 | rev)
                break
            fi
        fi
        sleep 1
    done

    if [[ -z "$TUNNEL_PORT" ]]; then
        err "Could not establish Pinggy tunnel. Log:"
        cat "$PINGGY_LOG"
        rm -f "$PINGGY_LOG"
        exit 1
    fi

    rm -f "$PINGGY_LOG"
    log "Tunnel established via Pinggy!"
    ;;

# ── SERVEO (no download, uses SSH port 22) ────────────────────
serveo)
    log "Starting SSH reverse tunnel via serveo.net..."
    SERVEO_LOG=$(mktemp /tmp/serveo_log.XXXXXX)

    ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R 0:localhost:22 serveo.net > "$SERVEO_LOG" 2>&1 &
    TUNNEL_PID=$!

    TUNNEL_PORT=""
    for i in $(seq 1 30); do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            break
        fi
        if [[ -s "$SERVEO_LOG" ]]; then
            # serveo outputs: "Forwarding TCP connections from serveo.net:PORT"
            TUNNEL_PORT=$(grep -oP 'serveo\.net:\K\d+' "$SERVEO_LOG" | head -1)
            [[ -n "$TUNNEL_PORT" ]] && break
        fi
        sleep 1
    done

    if [[ -z "$TUNNEL_PORT" ]]; then
        err "Could not establish serveo tunnel. Log:"
        cat "$SERVEO_LOG"
        rm -f "$SERVEO_LOG"
        # Try bore as fallback
        warn "Trying bore as fallback..."
        TUNNEL_METHOD="bore"
        rm -f "$SERVEO_LOG"
        exec bash "$0" bore
    fi

    TUNNEL_HOST="serveo.net"
    rm -f "$SERVEO_LOG"
    log "Tunnel established via serveo.net!"
    ;;

# ── BORE ──────────────────────────────────────────────────────
bore)
    if ! command -v bore &>/dev/null; then
        log "Downloading bore..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  BORE_ARCH="x86_64-unknown-linux-musl" ;;
            aarch64) BORE_ARCH="aarch64-unknown-linux-musl" ;;
            armv7l)  BORE_ARCH="armv7-unknown-linux-musleabihf" ;;
            *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        # Get latest version tag from GitHub API
        BORE_VERSION=$(curl -sI "https://github.com/ekzhang/bore/releases/latest" | grep -i "^location:" | grep -oP 'tag/\K[^\s\r]+')
        if [[ -z "$BORE_VERSION" ]]; then
            BORE_VERSION="v0.6.0"  # fallback
        fi
        BORE_URL="https://github.com/ekzhang/bore/releases/download/${BORE_VERSION}/bore-${BORE_VERSION}-${BORE_ARCH}.tar.gz"
        BORE_BIN="/tmp/bore"
        BORE_TMP=$(mktemp /tmp/bore_dl.XXXXXX)
        curl -sL "$BORE_URL" -o "$BORE_TMP"
        # Validate it's actually a gzip file
        if file "$BORE_TMP" | grep -q gzip; then
            tar xzf "$BORE_TMP" -C /tmp
            chmod +x "$BORE_BIN"
            log "bore ${BORE_VERSION} downloaded to /tmp/bore"
        else
            err "Download failed (not a valid archive). URL: $BORE_URL"
            rm -f "$BORE_TMP"
            exit 1
        fi
        rm -f "$BORE_TMP"
    else
        BORE_BIN=$(command -v bore)
    fi

    # Start bore in background and capture output
    BORE_LOG=$(mktemp /tmp/bore_log.XXXXXX)
    "$BORE_BIN" local 22 --to "$BORE_SERVER" > "$BORE_LOG" 2>&1 &
    TUNNEL_PID=$!

    # Wait for bore to connect and get the port
    log "Connecting to ${BORE_SERVER}..."
    TUNNEL_PORT=""
    for i in $(seq 1 30); do
        if [[ -s "$BORE_LOG" ]]; then
            TUNNEL_PORT=$(grep -oP 'bore\.pub:(\d+)' "$BORE_LOG" | head -1 | cut -d: -f2)
            if [[ -n "$TUNNEL_PORT" ]]; then
                break
            fi
            # Also try alternate format
            TUNNEL_PORT=$(grep -oP 'remote port \K\d+' "$BORE_LOG" | head -1)
            if [[ -n "$TUNNEL_PORT" ]]; then
                break
            fi
        fi
        sleep 1
    done

    if [[ -z "$TUNNEL_PORT" ]]; then
        # Show log for debugging
        err "Could not detect tunnel port. Bore log:"
        cat "$BORE_LOG"
        exit 1
    fi

    TUNNEL_HOST="$BORE_SERVER"
    log "Tunnel established!"
    rm -f "$BORE_LOG"
    ;;

# ── NGROK ─────────────────────────────────────────────────────
ngrok)
    NGROK_BIN=""
    if command -v ngrok &>/dev/null; then
        NGROK_BIN=$(command -v ngrok)
        log "ngrok found at $NGROK_BIN"
    else
        log "Downloading ngrok..."
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  NGROK_ARCH="amd64" ;;
            aarch64) NGROK_ARCH="arm64" ;;
            armv7l)  NGROK_ARCH="arm" ;;
            *)       err "Unsupported architecture: $ARCH"; exit 1 ;;
        esac
        NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-${NGROK_ARCH}.tgz"
        NGROK_TMP=$(mktemp /tmp/ngrok_dl.XXXXXX)
        curl -sL "$NGROK_URL" -o "$NGROK_TMP"
        if file "$NGROK_TMP" | grep -q gzip; then
            tar xzf "$NGROK_TMP" -C /tmp
            chmod +x /tmp/ngrok
            NGROK_BIN="/tmp/ngrok"
            log "ngrok downloaded to /tmp/ngrok"
        else
            err "Failed to download ngrok."
            rm -f "$NGROK_TMP"
            exit 1
        fi
        rm -f "$NGROK_TMP"
    fi

    # Check if auth token is configured
    if ! "$NGROK_BIN" config check &>/dev/null && [[ -z "${NGROK_AUTHTOKEN:-}" ]]; then
        echo ""
        echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ngrok needs a free auth token (one-time setup)       ║${NC}"
        echo -e "${YELLOW}║                                                        ║${NC}"
        echo -e "${YELLOW}║  1. Go to: https://dashboard.ngrok.com/signup          ║${NC}"
        echo -e "${YELLOW}║  2. Copy your auth token from the dashboard            ║${NC}"
        echo -e "${YELLOW}║  3. Paste it below                                     ║${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "  Paste your ngrok auth token: " NGROK_TOKEN
        if [[ -n "$NGROK_TOKEN" ]]; then
            "$NGROK_BIN" config add-authtoken "$NGROK_TOKEN"
            log "Auth token saved."
        else
            err "No token provided. Get one at https://dashboard.ngrok.com/signup"
            exit 1
        fi
    fi

    "$NGROK_BIN" tcp 22 --log=stdout --log-format=json > /tmp/ngrok_log.json 2>&1 &
    TUNNEL_PID=$!

    log "Starting ngrok tunnel..."
    TUNNEL_HOST=""
    TUNNEL_PORT=""
    for i in $(seq 1 30); do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            err "ngrok process died. Check auth token or network."
            cat /tmp/ngrok_log.json 2>/dev/null | tail -5
            exit 1
        fi
        if [[ -s /tmp/ngrok_log.json ]]; then
            URL=$(grep -oP '"url":"tcp://\K[^"]+' /tmp/ngrok_log.json | head -1)
            if [[ -n "$URL" ]]; then
                TUNNEL_HOST=$(echo "$URL" | cut -d: -f1)
                TUNNEL_PORT=$(echo "$URL" | cut -d: -f2)
                break
            fi
        fi
        sleep 1
    done

    if [[ -z "$TUNNEL_PORT" ]]; then
        err "Could not start ngrok tunnel."
        cat /tmp/ngrok_log.json 2>/dev/null | tail -10
        exit 1
    fi
    rm -f /tmp/ngrok_log.json
    log "Tunnel established via ngrok!"
    ;;

# ── TMATE ─────────────────────────────────────────────────────
tmate)
    if ! command -v tmate &>/dev/null; then
        log "Installing tmate..."
        install_pkg tmate
    fi

    # tmate gives a shared terminal, not full SSH
    warn "tmate provides a shared terminal session (not full machine SSH)."
    tmate -F 2>/dev/null &
    TUNNEL_PID=$!

    sleep 3
    TMATE_SSH=$(tmate display -p '#{tmate_ssh}' 2>/dev/null || true)
    TMATE_WEB=$(tmate display -p '#{tmate_web}' 2>/dev/null || true)

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}REMOTE SUPPORT SESSION READY (tmate)${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}SSH command:${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}$TMATE_SSH${NC}"
    echo -e "${CYAN}║${NC}"
    if [[ -n "$TMATE_WEB" ]]; then
    echo -e "${CYAN}║${NC}  ${BOLD}Web URL:${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}$TMATE_WEB${NC}"
    echo -e "${CYAN}║${NC}"
    fi
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Press Ctrl+C to end the session and clean up.${NC}"
    wait "$TUNNEL_PID" 2>/dev/null
    exit 0
    ;;

*)
    err "Unknown tunnel method: $TUNNEL_METHOD"
    err "Use: serveo, bore, ngrok, or tmate"
    exit 1
    ;;
esac

# ══════════════════════════════════════════════════════════════
#  STEP 4: DISPLAY CONNECTION INFO & AUTO-RECONNECT
# ══════════════════════════════════════════════════════════════
show_connection_info() {
    echo ""
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}🔗 REMOTE SUPPORT SESSION READY${NC}                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   From your ${BOLD}office PC${NC}, run:                           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${GREEN}ssh ${TEMP_USER}@${TUNNEL_HOST} -p ${TUNNEL_PORT}${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${BOLD}Password:${NC}  ${YELLOW}${TEMP_PASS}${NC}"
    echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}  ⏳ Session is active. Press Ctrl+C to end & clean up.${NC}"
    echo ""
}

# Function to start/restart bore tunnel
start_bore_tunnel() {
    BORE_LOG=$(mktemp /tmp/bore_log.XXXXXX)
    "$BORE_BIN" local 22 --to "$BORE_SERVER" > "$BORE_LOG" 2>&1 &
    TUNNEL_PID=$!

    TUNNEL_PORT=""
    for i in $(seq 1 30); do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            break  # process died
        fi
        if [[ -s "$BORE_LOG" ]]; then
            TUNNEL_PORT=$(grep -oP 'bore\.pub:(\d+)' "$BORE_LOG" | head -1 | cut -d: -f2)
            [[ -n "$TUNNEL_PORT" ]] && break
            TUNNEL_PORT=$(grep -oP 'remote port \K\d+' "$BORE_LOG" | head -1)
            [[ -n "$TUNNEL_PORT" ]] && break
        fi
        sleep 1
    done
    rm -f "$BORE_LOG"

    if [[ -n "$TUNNEL_PORT" ]]; then
        TUNNEL_HOST="$BORE_SERVER"
        return 0
    else
        return 1
    fi
}

show_connection_info

# Keep alive with auto-reconnect
MAX_RETRIES=10
RETRY_COUNT=0

while true; do
    # Wait for tunnel to die
    while kill -0 "$TUNNEL_PID" 2>/dev/null; do
        sleep 5
    done

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [[ $RETRY_COUNT -gt $MAX_RETRIES ]]; then
        err "Tunnel dropped $MAX_RETRIES times. Giving up."
        break
    fi

    warn "Tunnel dropped! Reconnecting... (attempt $RETRY_COUNT/$MAX_RETRIES)"
    sleep 2

    if start_bore_tunnel; then
        log "Reconnected!"
        show_connection_info
        RETRY_COUNT=0  # reset on successful reconnect
    else
        err "Reconnect failed."
    fi
done

