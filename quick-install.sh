#!/bin/bash

set -e

INSTALL_DIR="/opt/sing-box-warp"
CONFIG_DIR="/etc/sing-box-warp"
CACHE_DIR="/var/cache/sing-box-warp"
SERVICE_NAME="sing-box-warp"
SING_BOX_VERSION="1.13.2-extended-1.6.2"
SING_BOX_URL="https://gitea.digitalforest.my/hesoyam/sing-box-extended-mirror/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
REINSTALL=0

is_existing_install() {
    if [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        return 0
    fi
    if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "${SERVICE_NAME}"; then
        return 0
    fi
    if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        return 0
    fi
    if [ -f "$CONFIG_DIR/warp.conf" ]; then
        return 0
    fi
    return 1
}

stop_existing_service() {
    local running=0

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        running=1
        echo "Service ${SERVICE_NAME} is running, stopping..."
    elif systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "${SERVICE_NAME}"; then
        echo "Service ${SERVICE_NAME} is installed but not running, stopping..."
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    if pgrep -f "sing-box run -c ${INSTALL_DIR}/config.json" >/dev/null 2>&1; then
        echo "Stopping remaining sing-box processes..."
        pkill -f "sing-box run -c ${INSTALL_DIR}/config.json" 2>/dev/null || true
        sleep 1
    fi

    if [ "$running" -eq 1 ] || systemctl is-failed --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    fi
}

clean_existing_files() {
    echo "Removing previous installation files..."

    rm -rf "${INSTALL_DIR:?}"/*
    rm -f "$INSTALL_DIR/config.json" "$INSTALL_DIR/generate-config.sh" 2>/dev/null || true
    rm -rf "$INSTALL_DIR/rules"

    rm -f "$CONFIG_DIR/enable-tun" 2>/dev/null || true
    rm -f "$CONFIG_DIR/proton.conf" 2>/dev/null || true
    rm -f "$CONFIG_DIR/default-route" 2>/dev/null || true
    rm -rf "${CACHE_DIR:?}"/*
}

prepare_reinstall() {
    if ! is_existing_install; then
        return 0
    fi

    REINSTALL=1
    echo ""
    echo "=== Existing installation detected ==="
    stop_existing_service
    clean_existing_files
    systemctl daemon-reload 2>/dev/null || true
    echo "Ready for clean reinstall."
    echo ""
}

start_service() {
    echo "Generating config..."
    WARP_CONF="$CONFIG_DIR/warp.conf" \
    PROTON_CONF="$CONFIG_DIR/proton.conf" \
    OUTPUT_CONFIG="$INSTALL_DIR/config.json" \
    ENABLE_TUN_FILE="$CONFIG_DIR/enable-tun" \
    DEFAULT_ROUTE_FILE="$CONFIG_DIR/default-route" \
    "$INSTALL_DIR/generate-config.sh"

    echo "Starting ${SERVICE_NAME}..."
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager || true
}

# Extract a JSON string field value (flat JSON): json_get "<json>" "<key>"
json_get() {
    printf '%s' "$1" \
        | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*\"//; s/\"$//"
}

# Probe ip-api.com through a local SOCKS5 proxy on the given port.
# Prints 8 values separated by 0x1F: latency, status, country, regionName,
# city, timezone, isp, query.
probe_values() {
    local port="$1"
    local sep=$'\037'
    local resp tsec body ms status country regionName city timezone isp query

    resp=$(curl -s --connect-timeout 8 --max-time 15 \
        --proxy "socks5h://127.0.0.1:${port}" \
        -w $'\n%{time_total}' "http://ip-api.com/json" 2>/dev/null)

    tsec=$(printf '%s' "$resp" | tail -n1)
    body=$(printf '%s' "$resp" | sed '$d')

    if [ -z "$body" ] || ! printf '%s' "$body" | grep -q '"status"'; then
        printf 'ERR%sno response%s-%s-%s-%s-%s-%s-' \
            "$sep" "$sep" "$sep" "$sep" "$sep" "$sep" "$sep"
        return
    fi

    ms=$(awk "BEGIN{printf \"%d\", ${tsec:-0}*1000}")
    status=$(json_get "$body" status)
    country=$(json_get "$body" country)
    regionName=$(json_get "$body" regionName)
    city=$(json_get "$body" city)
    timezone=$(json_get "$body" timezone)
    isp=$(json_get "$body" isp)
    query=$(json_get "$body" query)

    printf '%sms%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
        "$ms" "$sep" "$status" "$sep" "$country" "$sep" "$regionName" \
        "$sep" "$city" "$sep" "$timezone" "$sep" "$isp" "$sep" "$query"
}

# Pad a string with trailing spaces to a given display width (char count).
_pad() {
    local s="$1" w="$2" len=${#1} i
    printf '%s' "$s"
    i=$len
    while [ "$i" -lt "$w" ]; do printf ' '; i=$((i + 1)); done
}

_dashes() {
    local i=0
    while [ "$i" -lt "$1" ]; do printf -- '-'; i=$((i + 1)); done
}

check_outbounds() {
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl not found, cannot run checks." >&2
        return 1
    fi

    local labels=("ms до ответа" "status" "country" "regionName" "city" "timezone" "isp" "query")
    local n=${#labels[@]}
    local -a warp_col=() proton_col=()
    local have_warp="$ENABLE_WARP" have_proton="$ENABLE_PROTON"
    local w0=4 ww=4 wp=6   # widths of "поле" / "warp" / "proton"
    local i

    if [ "$have_warp" -eq 1 ]; then
        echo "Probing WARP (socks5://127.0.0.1:2080) ..."
        IFS=$'\037' read -r -a warp_col <<< "$(probe_values 2080)"
    fi
    if [ "$have_proton" -eq 1 ]; then
        echo "Probing Proton (socks5://127.0.0.1:3080) ..."
        IFS=$'\037' read -r -a proton_col <<< "$(probe_values 3080)"
    fi

    for ((i = 0; i < n; i++)); do
        [ ${#labels[i]} -gt "$w0" ] && w0=${#labels[i]}
        if [ "$have_warp" -eq 1 ]; then [ ${#warp_col[i]} -gt "$ww" ] && ww=${#warp_col[i]}; fi
        if [ "$have_proton" -eq 1 ]; then [ ${#proton_col[i]} -gt "$wp" ] && wp=${#proton_col[i]}; fi
    done

    _sep_line() {
        printf '+'; _dashes $((w0 + 2)); printf '+'
        [ "$have_warp" -eq 1 ] && { _dashes $((ww + 2)); printf '+'; }
        [ "$have_proton" -eq 1 ] && { _dashes $((wp + 2)); printf '+'; }
        printf '\n'
    }
    _row() {
        printf '| '; _pad "$1" "$w0"; printf ' |'
        [ "$have_warp" -eq 1 ] && { printf ' '; _pad "$2" "$ww"; printf ' |'; }
        [ "$have_proton" -eq 1 ] && { printf ' '; _pad "$3" "$wp"; printf ' |'; }
        printf '\n'
    }

    echo ""
    _sep_line
    _row "поле" "warp" "proton"
    _sep_line
    for ((i = 0; i < n; i++)); do
        _row "${labels[i]}" "${warp_col[i]:--}" "${proton_col[i]:--}"
    done
    _sep_line
}

echo "=== Sing-Box WARP Quick Installer ==="
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo ""
echo "=== WARP Configuration (optional) ==="
echo "goto ->> https://warp-generator.github.io/ generater for AWG 3.0"
echo "WARP exposes a SOCKS5 proxy on port 2080."
read -p "Add WARP configuration? (y/n) " -n 1 -r < /dev/tty
echo
ENABLE_WARP=0
WARP_INPUT=""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Paste your WARP config (wg://... or [Interface]/[Peer] INI)."
    echo "Finish input with Ctrl-D."
    WARP_INPUT=$(cat < /dev/tty)
    if [ -z "$WARP_INPUT" ]; then
        echo "WARP input is empty, skipping WARP configuration."
    else
        ENABLE_WARP=1
    fi
else
    echo "Skipping WARP configuration."
fi

echo ""
echo "=== Proton Configuration (optional) ==="
echo "Proton (second WireGuard endpoint) exposes a SOCKS5 proxy on port 3080."
read -p "Add Proton configuration? (y/n) " -n 1 -r < /dev/tty
echo
ENABLE_PROTON=0
PROTON_INPUT=""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Paste your Proton config ([Interface]/[Peer] INI or wg://)."
    echo "Finish input with Ctrl-D."
    PROTON_INPUT=$(cat < /dev/tty)
    if [ -z "$PROTON_INPUT" ]; then
        echo "Proton input is empty, skipping Proton configuration."
    else
        ENABLE_PROTON=1
    fi
else
    echo "Skipping Proton configuration."
fi

if [ "$ENABLE_WARP" -eq 0 ] && [ "$ENABLE_PROTON" -eq 0 ]; then
    echo ""
    echo "Neither WARP nor Proton selected. Nothing to do, exiting."
    exit 0
fi

prepare_reinstall

echo "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$CACHE_DIR"

if [ "$ENABLE_WARP" -eq 1 ]; then
    printf "%s\n" "$WARP_INPUT" > "$CONFIG_DIR/warp.conf"
    echo "WARP configuration saved to $CONFIG_DIR/warp.conf"
else
    rm -f "$CONFIG_DIR/warp.conf"
fi

if [ "$ENABLE_PROTON" -eq 1 ]; then
    printf "%s\n" "$PROTON_INPUT" > "$CONFIG_DIR/proton.conf"
    echo "Proton configuration saved to $CONFIG_DIR/proton.conf"
else
    rm -f "$CONFIG_DIR/proton.conf"
fi

echo ""
echo "=== TUN mode ==="
echo "TUN routes system traffic through sing-box (needs CAP_NET_ADMIN)."
echo "Without TUN, only the SOCKS5 proxies are available."
read -p "Enable TUN mode? (y/n) " -n 1 -r < /dev/tty
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ENABLE_TUN=1
    echo "1" > "$CONFIG_DIR/enable-tun"
    echo "TUN mode enabled."
else
    ENABLE_TUN=0
    echo "0" > "$CONFIG_DIR/enable-tun"
    echo "TUN mode disabled (SOCKS5 only)."
fi

if [ "$ENABLE_WARP" -eq 1 ] && [ "$ENABLE_PROTON" -eq 1 ]; then
    echo ""
    echo "=== Default route ==="
    echo "Choose where all non-SOCKS traffic goes (TUN rules, routing lists, IP-leak sites)."
    echo "SOCKS inbounds always keep their own outbound: 2080 -> WARP, 3080 -> Proton."
    echo "  1) WARP   (warp-out)"
    echo "  2) Proton (proton-out)"
    read -p "Select default route [1/2] " -n 1 -r < /dev/tty
    echo
    if [[ $REPLY == "2" ]]; then
        DEFAULT_ROUTE="proton"
        echo "Default route: Proton (proton-out)."
    else
        DEFAULT_ROUTE="warp"
        echo "Default route: WARP (warp-out)."
    fi
elif [ "$ENABLE_PROTON" -eq 1 ]; then
    DEFAULT_ROUTE="proton"
    echo "Default route: Proton (proton-out) — only endpoint."
else
    DEFAULT_ROUTE="warp"
    echo "Default route: WARP (warp-out) — only endpoint."
fi
echo "$DEFAULT_ROUTE" > "$CONFIG_DIR/default-route"

echo ""
echo "Downloading sing-box..."
NEED_DOWNLOAD=1

if [ "$REINSTALL" -eq 1 ]; then
    echo "Reinstall: updating sing-box binary..."
    NEED_DOWNLOAD=1
elif command -v sing-box >/dev/null 2>&1; then
    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -n 1 || true)
    if echo "$INSTALLED_VERSION" | grep -q "$SING_BOX_VERSION"; then
        NEED_DOWNLOAD=0
        echo "sing-box already installed ($INSTALLED_VERSION), skipping download."
    else
        echo "sing-box is installed ($INSTALLED_VERSION) but version mismatch, downloading $SING_BOX_VERSION..."
    fi
fi

if [ "$NEED_DOWNLOAD" -eq 1 ]; then
    cd /tmp
    TARBALL="sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
    rm -f "$TARBALL"

    echo "Downloading $TARBALL ..."
    if ! wget -q --show-progress --timeout=20 --tries=3 --waitretry=5 --retry-connrefused --continue -O "$TARBALL" "$SING_BOX_URL"; then
        echo "wget failed, trying curl..."
        curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -o "$TARBALL" "$SING_BOX_URL"
    fi

    tar -xzf "$TARBALL"
    mv "sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box
    chmod +x /usr/local/bin/sing-box
    rm -rf "$TARBALL" "sing-box-${SING_BOX_VERSION}-linux-amd64"
fi

GENERATE_CONFIG_URL="https://gitea.digitalforest.my/hesoyam/sing-warp-socks5/raw/branch/main/generate-config.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing generate-config.sh..."
if [ -f "$SCRIPT_DIR/generate-config.sh" ]; then
    cp "$SCRIPT_DIR/generate-config.sh" "$INSTALL_DIR/generate-config.sh"
    echo "Copied generate-config.sh from installer directory."
elif wget -q --timeout=20 -O "$INSTALL_DIR/generate-config.sh" "$GENERATE_CONFIG_URL"; then
    echo "Downloaded generate-config.sh."
elif curl -fsSL --connect-timeout 20 -o "$INSTALL_DIR/generate-config.sh" "$GENERATE_CONFIG_URL"; then
    echo "Downloaded generate-config.sh (curl)."
else
    echo "Error: failed to install generate-config.sh"
    exit 1
fi

chmod +x "$INSTALL_DIR/generate-config.sh"

echo "Creating systemd service..."
cat > /etc/systemd/system/sing-box-warp.service <<"'SERVICE_EOF'"
[Unit]
Description=Sing-Box WARP SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/sing-box-warp
Environment="HOME=/var/cache/sing-box-warp"
Environment="WARP_CONF=/etc/sing-box-warp/warp.conf"
Environment="PROTON_CONF=/etc/sing-box-warp/proton.conf"
Environment="DEFAULT_ROUTE_FILE=/etc/sing-box-warp/default-route"
Environment="OUTPUT_CONFIG=/opt/sing-box-warp/config.json"
ExecStartPre=/opt/sing-box-warp/generate-config.sh
ExecStart=/usr/local/bin/sing-box run -c /opt/sing-box-warp/config.json
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/sing-box-warp /var/cache/sing-box-warp
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
'SERVICE_EOF'

echo "Configuring sysctl parameters..."
{
    echo "net.ipv4.conf.all.src_valid_mark=1"
    echo "net.ipv4.ip_forward=1"
    if [ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
        echo "net.ipv6.conf.all.disable_ipv6=0"
    fi
} > /etc/sysctl.d/99-sing-box-warp.conf
if [ ! -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]; then
    echo "IPv6 sysctl not available, skipping net.ipv6.conf.all.disable_ipv6."
fi
sysctl -p /etc/sysctl.d/99-sing-box-warp.conf

if [ "$ENABLE_TUN" = "1" ]; then
    RULES_BASE="https://gitea.digitalforest.my/hesoyam/srs-komplekt/raw/branch/main"
    echo "Downloading routing rule sets..."
    rm -rf "$INSTALL_DIR/rules"
    mkdir -p "$INSTALL_DIR/rules"
    wget -O "$INSTALL_DIR/rules/antifilter_allyouneed.srs" "$RULES_BASE/antifilter_allyouneed.srs"
    wget -O "$INSTALL_DIR/rules/antizapret.srs" "$RULES_BASE/antizapret.srs"
    wget -O "$INSTALL_DIR/rules/github_ip_you-oops-dev.srs" "$RULES_BASE/github_ip_you-oops-dev.srs"
    wget -O "$INSTALL_DIR/rules/github_karingx.srs" "$RULES_BASE/github_karingx.srs"
    wget -O "$INSTALL_DIR/rules/cloudfront_ip_MetaCubeX.srs" "$RULES_BASE/cloudfront_ip_MetaCubeX.srs"
    wget -O "$INSTALL_DIR/rules/telegram_MetaCubeX.srs" "$RULES_BASE/telegram_MetaCubeX.srs"
    wget -O "$INSTALL_DIR/rules/refilter_ipsum.srs" "$RULES_BASE/refilter_ipsum.srs"
    wget -O "$INSTALL_DIR/rules/canonical_MetaCubeX.srs" "$RULES_BASE/canonical_MetaCubeX.srs"
    wget -O "$INSTALL_DIR/rules/launchpad_KaringX.srs" "$RULES_BASE/launchpad_KaringX.srs"
    chmod -R 775 "$INSTALL_DIR/rules"
else
    echo "Skipping rule sets download (TUN disabled)."
    rm -rf "$INSTALL_DIR/rules"
fi

echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Service commands:"
echo "  Enable:  sudo systemctl enable sing-box-warp"
echo "  Start:   sudo systemctl start sing-box-warp"
echo "  Status:  sudo systemctl status sing-box-warp"
echo "  Logs:    sudo journalctl -u sing-box-warp -f"
echo ""
echo "SOCKS5 proxies:"
if [ "$ENABLE_WARP" -eq 1 ]; then
    echo "  WARP:   localhost:2080"
fi
if [ "$ENABLE_PROTON" -eq 1 ]; then
    echo "  Proton: localhost:3080"
fi
echo "  Default route for non-SOCKS traffic: $DEFAULT_ROUTE"
echo ""

SERVICE_STARTED=0
if [ "$REINSTALL" -eq 1 ]; then
    echo "Reinstall complete, starting service..."
    start_service
    SERVICE_STARTED=1
else
    read -p "Start service now? (y/n) " -n 1 -r < /dev/tty
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        start_service
        SERVICE_STARTED=1
    fi
fi

echo ""
read -p "Проверить созданные ауты? (y/n) " -n 1 -r < /dev/tty
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ "$SERVICE_STARTED" -eq 0 ] && ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Service is not running — starting it for the check..."
        start_service
    fi
    check_outbounds
fi

echo ""
echo "Done!"
