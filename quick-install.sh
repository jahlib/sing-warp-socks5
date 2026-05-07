#!/bin/bash

set -e

INSTALL_DIR="/opt/sing-box-warp"
CONFIG_DIR="/etc/sing-box-warp"
CACHE_DIR="/var/cache/sing-box-warp"
SING_BOX_VERSION="1.13.2-extended-1.6.2"
SING_BOX_URL="https://github.com/shtorm-7/sing-box-extended/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"

echo "=== Sing-Box WARP Quick Installer ==="
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$CACHE_DIR"

echo ""
echo "=== WARP Configuration ==="
echo "goto ->> https://warp-generator.github.io/ generater for AWG 3.0"
echo "Paste your WARP config (wg://... or [Interface]/[Peer] INI)."
echo "Finish input with Ctrl-D."
WARP_INPUT=$(cat < /dev/tty)

if [ -z "$WARP_INPUT" ]; then
    echo "Error: warp.conf input is empty!"
    exit 1
fi

printf "%s\n" "$WARP_INPUT" > "$CONFIG_DIR/warp.conf"

echo ""
echo "Configuration saved to $CONFIG_DIR/warp.conf"

echo ""
echo "Downloading sing-box..."
NEED_DOWNLOAD=1

if command -v sing-box >/dev/null 2>&1; then
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

echo "Creating generate-config.sh..."
cat > "$INSTALL_DIR/generate-config.sh" <<"'GENERATE_CONFIG_EOF'"
#!/bin/bash

WARP_CONF="${WARP_CONF:-/etc/sing-box-warp/warp.conf}"
OUTPUT_CONFIG="${OUTPUT_CONFIG:-/opt/sing-box-warp/config.json}"

urldecode() {
    echo "$1" | sed 's/%3[dD]/=/g; s/%2[bB]/+/g; s/%2[fF]/\//g; s/%2[cC]/,/g'
}

trim() {
    echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

normalize_cidr() {
    local addr
    local suffix
    addr=$(trim "$1")
    suffix="$2"

    if [ -z "$addr" ]; then
        echo ""
        return
    fi

    case "$addr" in
        */*) echo "$addr" ;;
        *) echo "${addr}/${suffix}" ;;
    esac
}

get_param() {
    local url="$1"
    local param="$2"
    echo "$url" | sed -n "s/.*[?&]${param}=\([^&#]*\).*/\1/p"
}

parse_from_wg_url() {
    WG_URL=$(grep "^wg://" "$WARP_CONF" | head -1)

    if [ -z "$WG_URL" ]; then
        echo "Error: No wg:// URL found in $WARP_CONF"
        exit 1
    fi

    SERVER=$(echo "$WG_URL" | sed 's|wg://\([^:]*\):.*|\1|')
    PORT=$(echo "$WG_URL" | sed 's|wg://[^:]*:\([0-9]*\)?.*|\1|')

    PRIVATE_KEY=$(urldecode "$(get_param "$WG_URL" "private_key")")
    PUBLIC_KEY=$(urldecode "$(get_param "$WG_URL" "peer_public_key")")
    MTU=$(get_param "$WG_URL" "mtu")
    LOCAL_ADDRESS=$(urldecode "$(get_param "$WG_URL" "local_address")")

    Jc=$(get_param "$WG_URL" "junk_packet_count")
    Jmin=$(get_param "$WG_URL" "junk_packet_min_size")
    Jmax=$(get_param "$WG_URL" "junk_packet_max_size")
    H1=$(get_param "$WG_URL" "init_packet_magic_header")
    H2=$(get_param "$WG_URL" "response_packet_magic_header")
    H3=$(get_param "$WG_URL" "underload_packet_magic_header")
    H4=$(get_param "$WG_URL" "transport_packet_magic_header")

    IPV4=$(echo "$LOCAL_ADDRESS" | tr ',-' '\n' | sed -n '1p')
    IPV6=$(echo "$LOCAL_ADDRESS" | tr ',-' '\n' | sed -n '2p')
    IPV4=$(normalize_cidr "$IPV4" 32)
    IPV6=$(normalize_cidr "$IPV6" 128)

    if [ -z "$IPV4" ]; then
        echo "Error: local_address (IPv4) is empty"
        exit 1
    fi

    ADDRESS_JSON=$(printf '"%s"' "$IPV4")

    MTU=${MTU:-1280}
    Jc=${Jc:-4}
    Jmin=${Jmin:-40}
    Jmax=${Jmax:-70}
    H1=${H1:-1}
    H2=${H2:-2}
    H3=${H3:-3}
    H4=${H4:-4}
    ALLOWED_IPS="0.0.0.0/0"
    TAG="wireguard-out"
    LOG_LEVEL="debug"
}

parse_from_ini() {
    local section=""
    local key=""
    local value=""

    while IFS= read -r line || [ -n "$line" ]; do
        line=$(trim "$line")
        [ -z "$line" ] && continue

        case "$line" in
            \#*|\;*) continue ;;
        esac

        case "$line" in
            "[Interface]") section="Interface"; continue ;;
            "[Peer]") section="Peer"; continue ;;
        esac

        key=$(trim "$(echo "$line" | cut -d'=' -f1)")
        value=$(trim "$(echo "$line" | cut -d'=' -f2-)")
        [ -z "$key" ] && continue

        if [ "$section" = "Interface" ]; then
            case "$key" in
                PrivateKey) PRIVATE_KEY="$value" ;;
                Address)
                    IPV4=$(trim "$(echo "$value" | cut -d',' -f1)")
                    IPV6=$(trim "$(echo "$value" | cut -d',' -f2)")
                    ;;
                MTU) MTU="$value" ;;
                S1) S1="$value" ;;
                S2) S2="$value" ;;
                S3) S3="$value" ;;
                Jc) Jc="$value" ;;
                Jmin) Jmin="$value" ;;
                Jmax) Jmax="$value" ;;
                H1) H1="$value" ;;
                H2) H2="$value" ;;
                H3) H3="$value" ;;
                H4) H4="$value" ;;
                I1) I1="$value" ;;
                I2) I2="$value" ;;
            esac
        elif [ "$section" = "Peer" ]; then
            case "$key" in
                PublicKey) PUBLIC_KEY="$value" ;;
                AllowedIPs)
                    if echo "$value" | grep -q "0.0.0.0/0"; then
                        ALLOWED_IPS="0.0.0.0/0"
                    else
                        ALLOWED_IPS=$(trim "$(echo "$value" | cut -d',' -f1)")
                    fi
                    ;;
                Endpoint)
                    SERVER=$(echo "$value" | cut -d':' -f1)
                    PORT=$(echo "$value" | cut -d':' -f2)
                    ;;
            esac
        fi
    done < "$WARP_CONF"

    IPV4=$(normalize_cidr "$IPV4" 32)
    IPV6=$(normalize_cidr "$IPV6" 128)

    if [ -z "$IPV4" ]; then
        echo "Error: Address (IPv4) is empty"
        exit 1
    fi

    ADDRESS_JSON=$(printf '"%s"' "$IPV4")

    MTU=${MTU:-1280}
    S1=${S1:-0}
    S2=${S2:-0}
    S3=${S3:-0}
    Jc=${Jc:-4}
    Jmin=${Jmin:-40}
    Jmax=${Jmax:-70}
    H1=${H1:-1}
    H2=${H2:-2}
    H3=${H3:-3}
    H4=${H4:-4}
    ALLOWED_IPS=${ALLOWED_IPS:-0.0.0.0/0}

    if [ -z "$SERVER" ] || [ -z "$PORT" ]; then
        echo "Error: Endpoint is empty"
        exit 1
    fi

    TAG="wireguard-out"
    LOG_LEVEL="error"
}

write_config() {
    if [ -n "$I1" ] || [ -n "$I2" ]; then
        H4_COMMA="," 
    else
        H4_COMMA=""
    fi

    if [ -n "$I1" ] && [ -n "$I2" ]; then
        I1_LINE=$(printf '        "i1": "%s",\n' "$I1")
        I2_LINE=$(printf '        "i2": "%s"\n' "$I2")
    elif [ -n "$I1" ]; then
        I1_LINE=$(printf '        "i1": "%s"\n' "$I1")
        I2_LINE=""
    elif [ -n "$I2" ]; then
        I1_LINE=""
        I2_LINE=$(printf '        "i2": "%s"\n' "$I2")
    else
        I1_LINE=""
        I2_LINE=""
    fi

    cat > "$OUTPUT_CONFIG" <<EOF
{
  "log": {
    "level": "$LOG_LEVEL"
  },
  "dns": {
    "servers": [
      {
        "tag": "default",
        "type": "udp",
        "server": "76.76.2.0",
        "detour": "direct"
      },
      {
        "tag": "dns-proxy",
        "type": "tls",
        "server": "8.8.8.8",
        "detour": "wireguard-out"
      },
      {
        "tag": "local",
        "type": "udp",
        "server": "127.0.0.1",
        "detour": "direct"
      }
    ]
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "$TAG",
      "mtu": $MTU,
      "address": $ADDRESS_JSON,
      "private_key": "$PRIVATE_KEY",
      "listen_port": 10000,
      "peers": [
        {
          "address": "$SERVER",
          "port": $PORT,
          "public_key": "$PUBLIC_KEY",
          "allowed_ips": "$ALLOWED_IPS"
        }
      ],
      "udp_timeout": "5m0s",
      "amnezia": {
        "jc": $Jc,
        "jmin": $Jmin,
        "jmax": $Jmax,
        "s1": ${S1:-0},
        "s2": ${S2:-0},
        "h1": $H1,
        "h2": $H2,
        "h3": $H3,
        "h4": $H4$H4_COMMA
$I1_LINE
$I2_LINE
      }
    }
  ],
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "$TAG",
    "default_domain_resolver": "default",
    "auto_detect_interface": true
  }
}
EOF
}

parse_warp_conf() {
    local first_line
    first_line=$(head -n 1 "$WARP_CONF" | tr -d '\r')
    first_line=$(trim "$first_line")

    if echo "$first_line" | grep -q "^wg://"; then
        parse_from_wg_url
    elif echo "$first_line" | grep -q "^\[Interface\]"; then
        parse_from_ini
    else
        echo "Error: Unsupported warp.conf format (expected wg:// or [Interface])"
        exit 1
    fi

    write_config
}

if [ ! -f "$WARP_CONF" ]; then
    echo "Error: $WARP_CONF not found!"
    exit 1
fi

parse_warp_conf
echo "Config generated successfully at $OUTPUT_CONFIG"
'GENERATE_CONFIG_EOF'

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
cat > /etc/sysctl.d/99-sing-box-warp.conf <<EOF
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
EOF
sysctl -p /etc/sysctl.d/99-sing-box-warp.conf

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
echo "SOCKS5 proxy: localhost:2080"
echo ""

read -p "Start service now? (y/n) " -n 1 -r < /dev/tty
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable sing-box-warp
    systemctl start sing-box-warp
    echo ""
    echo "Service started! Checking status..."
    sleep 2
    systemctl status sing-box-warp --no-pager
fi

echo ""
echo "Done!"
