#!/bin/bash

set -e

INSTALL_DIR="/opt/sing-box-warp"
CONFIG_DIR="/etc/sing-box-warp"
CACHE_DIR="/var/cache/sing-box-warp"
SING_BOX_VERSION="1.12.12-extended-1.5.1"
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
read -p "Enter your warp.conf URL (wg://...): " WARP_URL < /dev/tty

if [ -z "$WARP_URL" ]; then
    echo "Error: warp.conf URL is empty!"
    exit 1
fi

echo "$WARP_URL" > "$CONFIG_DIR/warp.conf"

echo ""
echo "Configuration saved to $CONFIG_DIR/warp.conf"

echo ""
echo "Downloading sing-box..."
cd /tmp
wget -q --show-progress "$SING_BOX_URL"
tar -xzf "sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
mv "sing-box-${SING_BOX_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box
chmod +x /usr/local/bin/sing-box
rm -rf "sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz" "sing-box-${SING_BOX_VERSION}-linux-amd64"

echo "Creating generate-config.sh..."
cat > "$INSTALL_DIR/generate-config.sh" <<"'GENERATE_CONFIG_EOF'"
#!/bin/bash

WARP_CONF="${WARP_CONF:-/etc/sing-box-warp/warp.conf}"
OUTPUT_CONFIG="${OUTPUT_CONFIG:-/opt/sing-box-warp/config.json}"

urldecode() {
    echo "$1" | sed 's/%3D/=/g; s/%2B/+/g; s/%2F/\//g'
}

get_param() {
    local url="$1"
    local param="$2"
    echo "$url" | sed -n "s/.*[?&]${param}=\([^&#]*\).*/\1/p"
}

parse_warp_conf() {
    WG_URL=$(grep "^wg://" "$WARP_CONF" | head -1)
    
    if [ -z "$WG_URL" ]; then
        echo "Error: No wg:// URL found in $WARP_CONF"
        exit 1
    fi
    
    SERVER=$(echo "$WG_URL" | sed 's|wg://\([^:]*\):.*|\1|')
    PORT=$(echo "$WG_URL" | sed 's|wg://[^:]*:\([0-9]*\)?.*|\1|')
    
    PRIVATE_KEY=$(urldecode "$(get_param "$WG_URL" "private_key")")
    PUBLIC_KEY=$(urldecode "$(get_param "$WG_URL" "peer_public_key")")
    RESERVED=$(get_param "$WG_URL" "reserved")
    MTU=$(get_param "$WG_URL" "mtu")
    LOCAL_ADDRESS=$(get_param "$WG_URL" "local_address")
    
    Jc=$(get_param "$WG_URL" "junk_packet_count")
    Jmin=$(get_param "$WG_URL" "junk_packet_min_size")
    Jmax=$(get_param "$WG_URL" "junk_packet_max_size")
    H1=$(get_param "$WG_URL" "init_packet_magic_header")
    H2=$(get_param "$WG_URL" "response_packet_magic_header")
    H3=$(get_param "$WG_URL" "underload_packet_magic_header")
    H4=$(get_param "$WG_URL" "transport_packet_magic_header")
    INIT_JUNK=$(get_param "$WG_URL" "init_packet_junk_size")
    RESP_JUNK=$(get_param "$WG_URL" "response_packet_junk_size")
    
    S1=$(echo "$RESERVED" | cut -d'-' -f1)
    S2=$(echo "$RESERVED" | cut -d'-' -f2)
    S3=$(echo "$RESERVED" | cut -d'-' -f3)
    
    IPV4=$(echo "$LOCAL_ADDRESS" | cut -d'-' -f1)
    IPV6=$(echo "$LOCAL_ADDRESS" | cut -d'-' -f2-)
    
    MTU=${MTU:-1280}
    Jc=${Jc:-4}
    Jmin=${Jmin:-40}
    Jmax=${Jmax:-70}
    H1=${H1:-1}
    H2=${H2:-2}
    H3=${H3:-3}
    H4=${H4:-4}
    INIT_JUNK=${INIT_JUNK:-0}
    RESP_JUNK=${RESP_JUNK:-0}
    S1=${S1:-0}
    S2=${S2:-0}
    S3=${S3:-0}
    
    echo "Parsed values:"
    echo "SERVER: $SERVER:$PORT"
    echo "PRIVATE_KEY: ${PRIVATE_KEY:0:20}..."
    echo "PUBLIC_KEY: ${PUBLIC_KEY:0:20}..."
    echo "RESERVED: [$S1, $S2, $S3]"
    echo "LOCAL_ADDRESS: $IPV4, $IPV6"
    echo "MTU: $MTU"
    echo "Amnezia: jc=$Jc, jmin=$Jmin, jmax=$Jmax, h1=$H1, h2=$H2, h3=$H3, h4=$H4"
    
    cat > "$OUTPUT_CONFIG" <<EOF
{
  "log": {
    "level": "info"
  },
  "dns": {
    "servers": [
      {
        "type": "local",
        "tag": "default"
      }
    ]
  },
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-out",
      "mtu": $MTU,
      "address": [
        "$IPV4",
        "$IPV6"
      ],
      "private_key": "$PRIVATE_KEY",
      "listen_port": 10000,
      "peers": [
        {
          "address": "$SERVER",
          "port": $PORT,
          "public_key": "$PUBLIC_KEY",
          "allowed_ips": ["0.0.0.0/0", "::/0"],
          "reserved": [$S1, $S2, $S3]
        }
      ],
      "udp_timeout": "5m0s",
      "amnezia": {
        "jc": $Jc,
        "jmin": $Jmin,
        "jmax": $Jmax,
        "h1": $H1,
        "h2": $H2,
        "h3": $H3,
        "h4": $H4
      }
    }
  ],
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
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
    "final": "warp-out",
    "default_domain_resolver": "default",
    "auto_detect_interface": true
  }
}
EOF
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
