#!/bin/sh

WARP_CONF="/app/warp.conf"
OUTPUT_CONFIG="/app/config.json"

# Extract value from WireGuard config format
get_config_value() {
    local file="$1"
    local key="$2"
    grep "^${key}" "$file" | head -1 | sed "s/^${key}[[:space:]]*=[[:space:]]*//" | tr -d '\r'
}

# Parse warp.conf
parse_warp_conf() {
    # Check if it's old wg:// URL format
    WG_URL=$(grep "^wg://" "$WARP_CONF" | head -1)
    
    if [ -n "$WG_URL" ]; then
        echo "Error: Old wg:// URL format detected. Please use WireGuard config format instead."
        echo "See README.md for the new format."
        exit 1
    fi
    
    # Parse WireGuard config format
    PRIVATE_KEY=$(get_config_value "$WARP_CONF" "PrivateKey")
    ADDRESS=$(get_config_value "$WARP_CONF" "Address")
    MTU=$(get_config_value "$WARP_CONF" "MTU")
    
    # Reserved bytes (S1-S4, но используем только первые 3)
    S1=$(get_config_value "$WARP_CONF" "S1")
    S2=$(get_config_value "$WARP_CONF" "S2")
    S3=$(get_config_value "$WARP_CONF" "S3")
    S4=$(get_config_value "$WARP_CONF" "S4")
    
    # Amnezia junk parameters
    Jc=$(get_config_value "$WARP_CONF" "Jc")
    Jmin=$(get_config_value "$WARP_CONF" "Jmin")
    Jmax=$(get_config_value "$WARP_CONF" "Jmax")
    
    # Magic headers
    H1=$(get_config_value "$WARP_CONF" "H1")
    H2=$(get_config_value "$WARP_CONF" "H2")
    H3=$(get_config_value "$WARP_CONF" "H3")
    H4=$(get_config_value "$WARP_CONF" "H4")
    
    # Init/Response packet junk (hex data) - пока не используем
    I1=$(get_config_value "$WARP_CONF" "I1")
    I2=$(get_config_value "$WARP_CONF" "I2")
    
    # Peer section
    PUBLIC_KEY=$(get_config_value "$WARP_CONF" "PublicKey")
    ENDPOINT=$(get_config_value "$WARP_CONF" "Endpoint")
    
    # Parse endpoint (format: host:port)
    SERVER=$(echo "$ENDPOINT" | cut -d':' -f1)
    PORT=$(echo "$ENDPOINT" | cut -d':' -f2)
    
    # Parse address - может быть несколько через запятую, берем первый IPv4
    IPV4=$(echo "$ADDRESS" | tr ',' '\n' | grep -v ':' | head -1 | tr -d ' ')
    IPV6=$(echo "$ADDRESS" | tr ',' '\n' | grep ':' | head -1 | tr -d ' ')
    
    # Если IPv6 не найден, генерируем дефолтный
    if [ -z "$IPV6" ]; then
        IPV6="2606:4700:110:8b6d:3808:7d65:ef2f:cc5d/128"
    fi
    
    # Validation
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
    
    # Set defaults if empty
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
    
    # Debug output
    echo "Parsed values:"
    echo "SERVER: $SERVER:$PORT"
    echo "PRIVATE_KEY: ${PRIVATE_KEY:0:20}..."
    echo "PUBLIC_KEY: ${PUBLIC_KEY:0:20}..."
    echo "RESERVED: [$S1, $S2, $S3]"
    echo "LOCAL_ADDRESS: $IPV4, $IPV6"
    echo "MTU: $MTU"
    echo "Amnezia: jc=$Jc, jmin=$Jmin, jmax=$Jmax, h1=$H1, h2=$H2, h3=$H3, h4=$H4"
    
    # Generate config.json
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

# Main
if [ ! -f "$WARP_CONF" ]; then
    echo "Error: $WARP_CONF not found!"
    exit 1
fi

parse_warp_conf
echo "Config generated successfully at $OUTPUT_CONFIG"
