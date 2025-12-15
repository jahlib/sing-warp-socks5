#!/bin/sh

WARP_CONF="/app/warp.conf"
OUTPUT_CONFIG="/app/config.json"

# URL decode function - only decode %3D to = for base64
urldecode() {
    echo "$1" | sed 's/%3D/=/g; s/%2B/+/g; s/%2F/\//g'
}

# Extract parameter from URL
get_param() {
    local url="$1"
    local param="$2"
    echo "$url" | sed -n "s/.*[?&]${param}=\([^&#]*\).*/\1/p"
}

# Parse warp.conf
parse_warp_conf() {
    # Read the wg:// URL from file
    WG_URL=$(grep "^wg://" "$WARP_CONF" | head -1)
    
    if [ -z "$WG_URL" ]; then
        echo "Error: No wg:// URL found in $WARP_CONF"
        exit 1
    fi
    
    # Extract server and port from wg://SERVER:PORT?...
    SERVER=$(echo "$WG_URL" | sed 's|wg://\([^:]*\):.*|\1|')
    PORT=$(echo "$WG_URL" | sed 's|wg://[^:]*:\([0-9]*\)?.*|\1|')
    
    # Extract parameters
    PRIVATE_KEY=$(urldecode "$(get_param "$WG_URL" "private_key")")
    PUBLIC_KEY=$(urldecode "$(get_param "$WG_URL" "peer_public_key")")
    RESERVED=$(get_param "$WG_URL" "reserved")
    MTU=$(get_param "$WG_URL" "mtu")
    LOCAL_ADDRESS=$(get_param "$WG_URL" "local_address")
    
    # Amnezia parameters
    Jc=$(get_param "$WG_URL" "junk_packet_count")
    Jmin=$(get_param "$WG_URL" "junk_packet_min_size")
    Jmax=$(get_param "$WG_URL" "junk_packet_max_size")
    H1=$(get_param "$WG_URL" "init_packet_magic_header")
    H2=$(get_param "$WG_URL" "response_packet_magic_header")
    H3=$(get_param "$WG_URL" "underload_packet_magic_header")
    H4=$(get_param "$WG_URL" "transport_packet_magic_header")
    INIT_JUNK=$(get_param "$WG_URL" "init_packet_junk_size")
    RESP_JUNK=$(get_param "$WG_URL" "response_packet_junk_size")
    
    # Parse reserved (format: 131-184-249)
    S1=$(echo "$RESERVED" | cut -d'-' -f1)
    S2=$(echo "$RESERVED" | cut -d'-' -f2)
    S3=$(echo "$RESERVED" | cut -d'-' -f3)
    
    # Parse local addresses (format: 172.16.0.2/32-2606:4700:110:8b6d:3808:7d65:ef2f:cc5d/128)
    IPV4=$(echo "$LOCAL_ADDRESS" | cut -d'-' -f1)
    IPV6=$(echo "$LOCAL_ADDRESS" | cut -d'-' -f2-)
    
    # Set defaults if empty
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
