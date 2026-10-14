#!/bin/sh

WARP_CONF="${WARP_CONF:-/etc/sing-box-warp/warp.conf}"
PROTON_CONF="${PROTON_CONF:-/etc/sing-box-warp/proton.conf}"
OUTPUT_CONFIG="${OUTPUT_CONFIG:-/opt/sing-box-warp/config.json}"
ENABLE_TUN_FILE="${ENABLE_TUN_FILE:-/etc/sing-box-warp/enable-tun}"
DEFAULT_ROUTE_FILE="${DEFAULT_ROUTE_FILE:-/etc/sing-box-warp/default-route}"

load_enable_tun() {
    local value

    value=$(trim "${ENABLE_TUN:-}")
    if [ -z "$value" ] && [ -f "$ENABLE_TUN_FILE" ]; then
        value=$(trim "$(cat "$ENABLE_TUN_FILE")")
    fi

    case "$value" in
        1|yes|true|y|Y|on|ON) ENABLE_TUN=1 ;;
        *) ENABLE_TUN=0 ;;
    esac
}

# Where all non-SOCKS traffic goes (TUN rules, routing lists, IP-leak sites).
# The SOCKS inbounds keep their own hard-coded outbound.
load_default_route() {
    local value

    value=$(trim "${DEFAULT_ROUTE:-}")
    if [ -z "$value" ] && [ -f "$DEFAULT_ROUTE_FILE" ]; then
        value=$(trim "$(cat "$DEFAULT_ROUTE_FILE")")
    fi

    case "$value" in
        2|proton|PROTON|Proton) DEFAULT_ROUTE=proton ;;
        *) DEFAULT_ROUTE=warp ;;
    esac
}

urldecode() {
    echo "$1" | sed 's/%3[dD]/=/g; s/%2[bB]/+/g; s/%2[fF]/\//g; s/%2[cC]/,/g'
}

trim() {
    echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Default-route NIC (eth0, ens3, enp0s3, …); override with TUN_EXCLUDE_INTERFACE
detect_default_interface() {
    local iface

    iface=$(trim "${TUN_EXCLUDE_INTERFACE:-}")
    if [ -n "$iface" ]; then
        echo "$iface"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip -4 route show default 2>/dev/null \
            | awk '/default/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        if [ -n "$iface" ]; then
            echo "$iface"
            return 0
        fi

        iface=$(ip -4 route get 1.1.1.1 2>/dev/null \
            | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
        if [ -n "$iface" ]; then
            echo "$iface"
            return 0
        fi
    fi

    if [ -r /proc/net/route ]; then
        iface=$(awk '$2 == "00000000" && $1 != "Iface" { print $1; exit }' /proc/net/route)
        if [ -n "$iface" ]; then
            echo "$iface"
            return 0
        fi
    fi

    return 1
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

# Convert a comma-separated AllowedIPs list into a JSON array body:
#   "0.0.0.0/0, ::/0"  ->  "0.0.0.0/0", "::/0"
build_allowed_ips_json() {
    local input
    local result=""
    local item
    local old_ifs

    input="$1"
    if [ -z "$input" ]; then
        echo '"0.0.0.0/0", "::/0"'
        return
    fi

    old_ifs="$IFS"
    IFS=','
    for item in $input; do
        item=$(trim "$item")
        [ -z "$item" ] && continue
        if [ -z "$result" ]; then
            result="\"$item\""
        else
            result="$result, \"$item\""
        fi
    done
    IFS="$old_ifs"

    if [ -z "$result" ]; then
        result='"0.0.0.0/0", "::/0"'
    fi
    echo "$result"
}

# Extract parameter from URL
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
    TAG="warp-out"
    LOG_LEVEL="error"
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

    TAG="warp-out"
    LOG_LEVEL="error"
}

parse_proton_from_ini() {
    local section=""
    local key=""
    local value=""
    local p_ipv4=""
    local p_allowed=""

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
                PrivateKey) PROTON_PRIVATE_KEY="$value" ;;
                Address) p_ipv4=$(trim "$(echo "$value" | cut -d',' -f1)") ;;
                MTU) PROTON_MTU="$value" ;;
            esac
        elif [ "$section" = "Peer" ]; then
            case "$key" in
                PublicKey) PROTON_PUBLIC_KEY="$value" ;;
                AllowedIPs) p_allowed="$value" ;;
                Endpoint)
                    PROTON_SERVER=$(echo "$value" | cut -d':' -f1)
                    PROTON_PORT=$(echo "$value" | cut -d':' -f2)
                    ;;
            esac
        fi
    done < "$PROTON_CONF"

    PROTON_ADDRESS=$(normalize_cidr "$p_ipv4" 32)
    PROTON_ALLOWED_IPS=$(build_allowed_ips_json "$p_allowed")
}

parse_proton_from_wg_url() {
    local url
    local local_addr
    local p_ipv4

    url=$(grep "^wg://" "$PROTON_CONF" | head -1)

    PROTON_SERVER=$(echo "$url" | sed 's|wg://\([^:]*\):.*|\1|')
    PROTON_PORT=$(echo "$url" | sed 's|wg://[^:]*:\([0-9]*\)?.*|\1|')
    PROTON_PRIVATE_KEY=$(urldecode "$(get_param "$url" "private_key")")
    PROTON_PUBLIC_KEY=$(urldecode "$(get_param "$url" "peer_public_key")")
    PROTON_MTU=$(get_param "$url" "mtu")

    local_addr=$(urldecode "$(get_param "$url" "local_address")")
    p_ipv4=$(echo "$local_addr" | tr ',-' '\n' | sed -n '1p')
    PROTON_ADDRESS=$(normalize_cidr "$p_ipv4" 32)
    PROTON_ALLOWED_IPS='"0.0.0.0/0", "::/0"'
}

parse_proton_conf() {
    local first_line
    first_line=$(head -n 1 "$PROTON_CONF" | tr -d '\r')
    first_line=$(trim "$first_line")

    if echo "$first_line" | grep -q "^wg://"; then
        parse_proton_from_wg_url
    elif echo "$first_line" | grep -q "^\[Interface\]"; then
        parse_proton_from_ini
    else
        echo "Error: Unsupported proton.conf format (expected wg:// or [Interface])"
        exit 1
    fi

    PROTON_MTU=${PROTON_MTU:-1280}

    if [ -z "$PROTON_PRIVATE_KEY" ] || [ -z "$PROTON_PUBLIC_KEY" ] \
        || [ -z "$PROTON_SERVER" ] || [ -z "$PROTON_PORT" ] \
        || [ -z "$PROTON_ADDRESS" ]; then
        echo "Error: proton.conf is missing required fields (PrivateKey/PublicKey/Endpoint/Address)"
        exit 1
    fi

    ENABLE_PROTON=1
}

# Join non-empty JSON object strings with ",\n" separators (for arrays).
join_objects() {
    local out=""
    local item
    for item in "$@"; do
        [ -z "$item" ] && continue
        if [ -z "$out" ]; then
            out="$item"
        else
            out="$out,
$item"
        fi
    done
    printf '%s' "$out"
}

write_config() {
    LOG_LEVEL="${LOG_LEVEL:-error}"

    # SOCKS inbound tag for WARP. Kept as "mixed-in" in WARP-only mode for
    # backwards compatibility, "warp-in" when Proton is present too.
    if [ "$ENABLE_PROTON" = "1" ]; then
        WARP_IN_TAG="warp-in"
    else
        WARP_IN_TAG="mixed-in"
    fi

    # Default outbound for everything that is not a hard SOCKS rule
    # (TUN rules, routing lists, IP-leak sites, proxy DNS).
    # With both endpoints the user's choice wins; otherwise the only
    # available endpoint becomes the default.
    if [ "$ENABLE_WARP" = "1" ] && [ "$ENABLE_PROTON" = "1" ]; then
        if [ "$DEFAULT_ROUTE" = "proton" ]; then
            DEFAULT_OUTBOUND="proton-out"
        else
            DEFAULT_OUTBOUND="warp-out"
        fi
    elif [ "$ENABLE_PROTON" = "1" ]; then
        DEFAULT_OUTBOUND="proton-out"
    else
        DEFAULT_OUTBOUND="warp-out"
    fi
    echo "Default route outbound: $DEFAULT_OUTBOUND" >&2

    if [ "$ENABLE_TUN" = "1" ]; then
        EXCLUDE_IFACE=$(detect_default_interface) || {
            echo "Warning: could not detect default network interface, using eth0" >&2
            EXCLUDE_IFACE="eth0"
        }
        echo "TUN enabled, exclude_interface: $EXCLUDE_IFACE" >&2
        TUN_INBOUND_BODY=$(cat <<TUNEOF
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sing0",
      "address": [
        "172.42.0.1/30"
      ],
      "mtu": 1500,
      "auto_route": true,
      "strict_route": false,
      "auto_redirect": true,
      "sniff": true,
      "sniff_override_destination": true,
      "endpoint_independent_nat": false,
      "stack": "system",
      "domain_strategy": "prefer_ipv4",
      "exclude_interface": [
        "$EXCLUDE_IFACE"
      ]
    }
TUNEOF
)
        TUN_ROUTE_RULE_PART=$(cat <<'RULEEOF'
,
      {
        "inbound": "tun-in",
        "action": "sniff",
        "timeout": "1s",
        "network": [
          "tcp",
          "udp",
          "quic"
        ]
      }
RULEEOF
)
        RULE_SET_RULE_PART=$(cat <<RULEEOF
,
      {
        "rule_set": [
          "antifilter_allyouneed",
          "antizapret",
          "cloudfront_ip_MetaCubeX",
          "github_ip_you-oops-dev",
          "github_karingx",
          "telegram_MetaCubeX",
          "refilter_ipsum",
          "canonical_MetaCubeX",
          "launchpad_KaringX"
        ],
        "outbound": "$DEFAULT_OUTBOUND"
      }
RULEEOF
)
        ROUTE_RULE_SET_SECTION=$(cat <<'DEFSEOF'
    "rule_set": [
      {
        "tag": "antifilter_allyouneed",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/antifilter_allyouneed.srs"
      },
      {
        "tag": "antizapret",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/antizapret.srs"
      },
      {
        "tag": "cloudfront_ip_MetaCubeX",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/cloudfront_ip_MetaCubeX.srs"
      },
      {
        "tag": "github_ip_you-oops-dev",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/github_ip_you-oops-dev.srs"
      },
      {
        "tag": "github_karingx",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/github_karingx.srs"
      },
      {
        "tag": "telegram_MetaCubeX",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/telegram_MetaCubeX.srs"
      },
      {
        "tag": "refilter_ipsum",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/refilter_ipsum.srs"
      },
      {
        "tag": "canonical_MetaCubeX",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/canonical_MetaCubeX.srs"
      },
      {
        "tag": "launchpad_KaringX",
        "type": "local",
        "format": "binary",
        "path": "/opt/sing-box-warp/rules/launchpad_KaringX.srs"
      }
    ],
DEFSEOF
)
    else
        echo "TUN disabled (SOCKS5 only)" >&2
        TUN_INBOUND_BODY=""
        TUN_ROUTE_RULE_PART=""
        RULE_SET_RULE_PART=""
        ROUTE_RULE_SET_SECTION=""
    fi

    # --- AmneziaWG i1/i2 lines (WARP only) ---
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

    # --- WARP endpoint / inbound / route rule ---
    if [ "$ENABLE_WARP" = "1" ]; then
        echo "WARP enabled, adding $TAG endpoint and $WARP_IN_TAG inbound (:2080)" >&2
        WARP_ENDPOINT_BODY=$(cat <<WARPEOF
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
          "allowed_ips": "$ALLOWED_IPS",
          "persistent_keepalive_interval": 25
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
WARPEOF
)
        WARP_INBOUND_BODY=$(cat <<WARPEOF
    {
      "type": "mixed",
      "tag": "$WARP_IN_TAG",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
WARPEOF
)
        WARP_ROUTE_RULE=$(cat <<WARPEOF
      {
        "inbound": "$WARP_IN_TAG",
        "outbound": "warp-out"
      }
WARPEOF
)
    else
        echo "WARP disabled" >&2
        WARP_ENDPOINT_BODY=""
        WARP_INBOUND_BODY=""
        WARP_ROUTE_RULE=""
    fi

    # --- Proton endpoint / inbound / route rule ---
    if [ "$ENABLE_PROTON" = "1" ]; then
        echo "Proton enabled, adding proton-out endpoint and proton-in inbound (:3080)" >&2
        PROTON_ENDPOINT_BODY=$(cat <<PROTONEOF
    {
      "type": "wireguard",
      "tag": "proton-out",
      "mtu": $PROTON_MTU,
      "address": [
        "$PROTON_ADDRESS"
      ],
      "private_key": "$PROTON_PRIVATE_KEY",
      "listen_port": 10004,
      "peers": [
        {
          "address": "$PROTON_SERVER",
          "port": $PROTON_PORT,
          "public_key": "$PROTON_PUBLIC_KEY",
          "allowed_ips": [$PROTON_ALLOWED_IPS]
        }
      ],
      "udp_timeout": "5m0s"
    }
PROTONEOF
)
        PROTON_INBOUND_BODY=$(cat <<'PROTONEOF'
    {
      "type": "mixed",
      "tag": "proton-in",
      "listen": "127.0.0.1",
      "listen_port": 3080
    }
PROTONEOF
)
        PROTON_ROUTE_RULE=$(cat <<'PROTONEOF'
      {
        "inbound": "proton-in",
        "outbound": "proton-out"
      }
PROTONEOF
)
    else
        echo "Proton disabled" >&2
        PROTON_ENDPOINT_BODY=""
        PROTON_INBOUND_BODY=""
        PROTON_ROUTE_RULE=""
    fi

    # --- Assemble dynamic arrays ---
    ENDPOINTS_BODY=$(join_objects "$WARP_ENDPOINT_BODY" "$PROTON_ENDPOINT_BODY")
    INBOUNDS_BODY=$(join_objects "$WARP_INBOUND_BODY" "$PROTON_INBOUND_BODY" "$TUN_INBOUND_BODY")
    SOCKS_ROUTE_RULES=$(join_objects "$WARP_ROUTE_RULE" "$PROTON_ROUTE_RULE")

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
        "detour": "$DEFAULT_OUTBOUND"
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
$ENDPOINTS_BODY
  ],
  "inbounds": [
$INBOUNDS_BODY
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }$TUN_ROUTE_RULE_PART,
      {
        "ip_is_private": true,
        "outbound": "direct"
      },
$SOCKS_ROUTE_RULES,
      {
        "protocol": "dns",
        "action": "hijack-dns"
      },
      {
        "domain_suffix": [
          "myip.wtf",
          "my-ip.io",
          "ipify.org",
          "myip.la",
          "ip-api.com",
          "ipleak.net",
          "1e100.net",
          "browserleaks.com",
          "2ip.io",
          "2ipcore.com",
          "ipecho.net",
          "ip.sb"
        ],
        "outbound": "$DEFAULT_OUTBOUND"
      }$RULE_SET_RULE_PART
    ],
$ROUTE_RULE_SET_SECTION
    "final": "direct",
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

    ENABLE_WARP=1
}

# Main
ENABLE_WARP=0
ENABLE_PROTON=0
load_enable_tun
load_default_route

if [ -f "$WARP_CONF" ] && [ -s "$WARP_CONF" ]; then
    parse_warp_conf
fi

if [ -f "$PROTON_CONF" ] && [ -s "$PROTON_CONF" ]; then
    parse_proton_conf
fi

if [ "$ENABLE_WARP" != "1" ] && [ "$ENABLE_PROTON" != "1" ]; then
    echo "Error: neither WARP ($WARP_CONF) nor Proton ($PROTON_CONF) config provided, nothing to generate"
    exit 1
fi

write_config
echo "Config generated successfully at $OUTPUT_CONFIG"
