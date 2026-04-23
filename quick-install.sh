#!/bin/bash

set -e

INSTALL_DIR="/opt/sing-box-warp"
CONFIG_DIR="/etc/sing-box-warp"
CACHE_DIR="/var/cache/sing-box-warp"
SING_BOX_VERSION="v1.13.2-extended-1.6.2"
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
echo "Paste your WireGuard config (press Ctrl+D when done):"
echo ""

WARP_CONFIG=$(cat < /dev/tty)

if [ -z "$WARP_CONFIG" ]; then
    echo "Error: Configuration is empty!"
    exit 1
fi

echo "$WARP_CONFIG" > "$CONFIG_DIR/warp.conf"

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

get_config_value() {
    local file="$1"
    local key="$2"
    grep "^${key}" "$file" | head -1 | sed "s/^${key}[[:space:]]*=[[:space:]]*//" | tr -d '\r'
}

parse_warp_conf() {
    WG_URL=$(grep "^wg://" "$WARP_CONF" | head -1)
    
    if [ -n "$WG_URL" ]; then
        echo "Error: Old wg:// URL format detected. Please use WireGuard config format instead."
        exit 1
    fi
    
    PRIVATE_KEY=$(get_config_value "$WARP_CONF" "PrivateKey")
    ADDRESS=$(get_config_value "$WARP_CONF" "Address")
    MTU=$(get_config_value "$WARP_CONF" "MTU")
    
    S1=$(get_config_value "$WARP_CONF" "S1")
    S2=$(get_config_value "$WARP_CONF" "S2")
    S3=$(get_config_value "$WARP_CONF" "S3")
    S4=$(get_config_value "$WARP_CONF" "S4")
    
    Jc=$(get_config_value "$WARP_CONF" "Jc")
    Jmin=$(get_config_value "$WARP_CONF" "Jmin")
    Jmax=$(get_config_value "$WARP_CONF" "Jmax")
    
    H1=$(get_config_value "$WARP_CONF" "H1")
    H2=$(get_config_value "$WARP_CONF" "H2")
    H3=$(get_config_value "$WARP_CONF" "H3")
    H4=$(get_config_value "$WARP_CONF" "H4")
    
    I1=$(get_config_value "$WARP_CONF" "I1")
    I2=$(get_config_value "$WARP_CONF" "I2")
    
    PUBLIC_KEY=$(get_config_value "$WARP_CONF" "PublicKey")
    ENDPOINT=$(get_config_value "$WARP_CONF" "Endpoint")
    
    SERVER=$(echo "$ENDPOINT" | cut -d':' -f1)
    PORT=$(echo "$ENDPOINT" | cut -d':' -f2)
    
    IPV4=$(echo "$ADDRESS" | tr ',' '\n' | grep -v ':' | head -1 | tr -d ' ')
    IPV6=$(echo "$ADDRESS" | tr ',' '\n' | grep ':' | head -1 | tr -d ' ')
    
    if [ -z "$IPV6" ]; then
        IPV6="2606:4700:110:8b6d:3808:7d65:ef2f:cc5d/128"
    fi
    
    if [ -z "$PRIVATE_KEY" ]; then
        echo "Error: PrivateKey not found in config"
        exit 1
    fi
    
    if [ -z "$PUBLIC_KEY" ]; then
        echo "Error: PublicKey not found in config"
        exit 1
    fi
    
    if [ -z "$ENDPOINT" ]; then
        echo "Error: Endpoint not found in config"
        exit 1
    fi
    
    MTU=${MTU:-1280}
    Jc=${Jc:-4}
    Jmin=${Jmin:-40}
    Jmax=${Jmax:-70}
    H1=${H1:-1}
    H2=${H2:-2}
    H3=${H3:-3}
    H4=${H4:-4}
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
