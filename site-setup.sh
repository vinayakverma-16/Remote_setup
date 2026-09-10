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
TUNNEL_METHOD="${1:-bore}"          # bore | ngrok | tmate
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
        BORE_URL="https://github.com/ekzhang/bore/releases/latest/download/bore-${BORE_ARCH}.tar.gz"
        BORE_BIN="/tmp/bore"
        curl -sL "$BORE_URL" | tar xz -C /tmp
        chmod +x "$BORE_BIN"
        log "bore downloaded to /tmp/bore"
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
    if ! command -v ngrok &>/dev/null; then
        err "ngrok not found. Install it first: https://ngrok.com/download"
        err "After install, run: ngrok config add-authtoken YOUR_TOKEN"
        exit 1
    fi

    ngrok tcp 22 --log=stdout --log-format=json > /tmp/ngrok_log.json 2>&1 &
    TUNNEL_PID=$!

    log "Starting ngrok tunnel..."
    TUNNEL_HOST=""
    TUNNEL_PORT=""
    for i in $(seq 1 20); do
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
        err "Could not start ngrok. Is your auth token set?"
        exit 1
    fi
    rm -f /tmp/ngrok_log.json
    log "Tunnel established!"
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
    err "Use: bore, ngrok, or tmate"
    exit 1
    ;;
esac

# ══════════════════════════════════════════════════════════════
#  STEP 4: DISPLAY CONNECTION INFO
# ══════════════════════════════════════════════════════════════
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

# Keep alive — wait for Ctrl+C
while kill -0 "$TUNNEL_PID" 2>/dev/null; do
    sleep 5
done

warn "Tunnel process ended unexpectedly."
