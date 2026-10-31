read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    # 缓存仅提供非事实设置；协议状态始终由 config.json 推导。
    CUSTOM_IP=""
    LOG_ENABLED="false"
    HY2_HOPPING_ENABLED=false; HY2_HOP_START=""; HY2_HOP_END=""; HY2_HOP_INTERVAL=15
    HY2_BRUTAL_ENABLED=false; HY2_CLIENT_UP_MBPS=""; HY2_CLIENT_DOWN_MBPS=""; HY2_LEGACY_CONGESTION=false
    if [ -f "$CACHE_FILE" ]; then
        . "$CACHE_FILE"
    fi
    REALITY_PUB=""
    ENABLE_SS=false; ENABLE_HY2=false; ENABLE_TUIC=false
    ENABLE_REALITY=false; ENABLE_ANYTLS=false
    local protocol_key selector protocol_type protocol_count user_count
    for protocol_key in ss hy2 tuic reality anytls; do
        selector=$(protocol_selector "$protocol_key")
        protocol_type=$(protocol_type "$protocol_key")
        protocol_count=$(jq "[.inbounds[]? | select($selector)] | length" "$CONFIG_PATH") || return 1
        if [ "$protocol_count" -gt 1 ]; then
            err "检测到多个受管理的 $protocol_type inbound，协议管理拒绝自动修改"
            return 1
        fi
        if [ "$protocol_count" -eq 1 ]; then
            user_count=$(jq "[.inbounds[]? | select($selector) | .users[]?] | length" "$CONFIG_PATH") || return 1
            if [ "$user_count" -gt 1 ]; then
                err "检测到多用户 $protocol_type inbound，协议管理拒绝自动修改"
                return 1
            fi
            flag=$(protocol_flag "$protocol_key")
            printf -v "$flag" '%s' true
        fi
    done
    if ! jq -e '[.inbounds[]? | select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true) | {private_key:.tls.reality.private_key,short_id:.tls.reality.short_id[0],server_name:(.tls.server_name // .tls.reality.handshake.server)}] | unique | length <= 1' "$CONFIG_PATH" >/dev/null; then
        err 'VLESS/AnyTLS Reality 共享参数不一致，协议管理拒绝重建链接'
        return 1
    fi
    REALITY_SNI="addons.mozilla.org"

    # 读取各协议配置
    if [ "${ENABLE_SS:-false}" = "true" ]; then
        SS_PORT=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .listen_port // empty' "$CONFIG_PATH") || return 1
        SS_PSK=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .password // empty' "$CONFIG_PATH") || return 1
        SS_METHOD=$(jq -r '.inbounds[] | select(.type=="shadowsocks") | .method // empty' "$CONFIG_PATH") || return 1
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        HY2_PORT=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port // empty' "$CONFIG_PATH") || return 1
        HY2_PSK=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .users[0].password // empty' "$CONFIG_PATH") || return 1
        HY2_HOPPING_ENABLED=${HY2_HOPPING_ENABLED:-false}
        HY2_HOP_START=${HY2_HOP_START:-}
        HY2_HOP_END=${HY2_HOP_END:-}
        HY2_HOP_INTERVAL=${HY2_HOP_INTERVAL:-15}
        case "$HY2_HOPPING_ENABLED" in
            true)
                validate_hy2_hopping_settings "$HY2_HOP_START" "$HY2_HOP_END" "$HY2_HOP_INTERVAL" "$HY2_PORT" || return 1
                HY2_HOP_START=$((10#$HY2_HOP_START)); HY2_HOP_END=$((10#$HY2_HOP_END)); HY2_HOP_INTERVAL=$((10#$HY2_HOP_INTERVAL))
                validate_hy2_port_conflicts "$CONFIG_PATH" "$HY2_HOP_START" "$HY2_HOP_END" || return 1
                ;;
            false) HY2_HOP_START=""; HY2_HOP_END="" ;;
            *) err 'HY2_HOPPING_ENABLED 缓存值无效'; return 1 ;;
        esac
        [[ "$HY2_HOP_INTERVAL" =~ ^[0-9]+$ ]] || { err 'HY2_HOP_INTERVAL 缓存值无效'; return 1; }
        HY2_HOP_INTERVAL=$((10#$HY2_HOP_INTERVAL))
        (( HY2_HOP_INTERVAL >= 5 && HY2_HOP_INTERVAL <= 3600 )) || { err 'HY2_HOP_INTERVAL 缓存值无效'; return 1; }
        HY2_BRUTAL_ENABLED=${HY2_BRUTAL_ENABLED:-false}
        HY2_CLIENT_UP_MBPS=${HY2_CLIENT_UP_MBPS:-}
        HY2_CLIENT_DOWN_MBPS=${HY2_CLIENT_DOWN_MBPS:-}
        local hy2_up hy2_down hy2_ignore
        hy2_up=$(jq -r '.inbounds[]|select(.type=="hysteria2")|.up_mbps // empty' "$CONFIG_PATH") || return 1
        hy2_down=$(jq -r '.inbounds[]|select(.type=="hysteria2")|.down_mbps // empty' "$CONFIG_PATH") || return 1
        hy2_ignore=$(jq -r '.inbounds[]|select(.type=="hysteria2")|.ignore_client_bandwidth // empty' "$CONFIG_PATH") || return 1
        if [ -n "$hy2_up" ] && [ -n "$hy2_down" ] && [ "$hy2_ignore" = true ] && [[ "$hy2_up" =~ ^[1-9][0-9]*$ && "$hy2_down" =~ ^[1-9][0-9]*$ ]]; then
            HY2_BRUTAL_ENABLED=true
            HY2_CLIENT_UP_MBPS=$hy2_down
            HY2_CLIENT_DOWN_MBPS=$hy2_up
        elif [ -z "$hy2_up" ] && [ -z "$hy2_down" ] && [ "$hy2_ignore" = true ]; then
            HY2_BRUTAL_ENABLED=false
        elif [ -z "$hy2_up" ] && [ -z "$hy2_down" ] && [ -z "$hy2_ignore" ]; then
            HY2_BRUTAL_ENABLED=false
            HY2_LEGACY_CONGESTION=true
        else
            err 'HY2 拥塞控制配置非规范（ignore_client_bandwidth/up_mbps/down_mbps），拒绝自动修改'
            return 1
        fi
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        TUIC_PORT=$(jq -r '.inbounds[] | select(.type=="tuic") | .listen_port // empty' "$CONFIG_PATH") || return 1
        TUIC_UUID=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].uuid // empty' "$CONFIG_PATH") || return 1
        TUIC_PSK=$(jq -r '.inbounds[] | select(.type=="tuic") | .users[0].password // empty' "$CONFIG_PATH") || return 1
    fi

# Reality 公共参数（Reality / AnyTLS 共用）
if [ "${ENABLE_REALITY:-false}" = "true" ] || [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    # 在 jq 内选择首个共享入站，避免 head 提前关闭管道导致 pipefail。
    REALITY_SID=$(jq -r '
        [.inbounds[] | select((.type == "vless" or .type == "anytls") and .tls.reality.enabled == true)][0]
        | .tls.reality.short_id[0] // empty
    ' "$CONFIG_PATH") || return 1
    REALITY_PK=$(jq -r '[.inbounds[] | select((.type == "vless" or .type == "anytls") and .tls.reality.enabled == true)][0] | .tls.reality.private_key // empty' "$CONFIG_PATH") || return 1
    REALITY_SNI=$(jq -r '[.inbounds[] | select((.type == "vless" or .type == "anytls") and .tls.reality.enabled == true)][0] | .tls.server_name // .tls.reality.handshake.server // empty' "$CONFIG_PATH") || return 1
    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    [ -f "$CONFIG_DIR/.reality_pub" ] && REALITY_PUB=$(cat "$CONFIG_DIR/.reality_pub")
fi

# VLESS Reality 专属参数
if [ "${ENABLE_REALITY:-false}" = "true" ]; then
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .listen_port // empty' "$CONFIG_PATH") || return 1

    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .users[0].uuid // empty' "$CONFIG_PATH") || return 1

    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless" and .tls.reality.enabled==true) | .tls.reality.private_key // empty' "$CONFIG_PATH") || return 1
fi

if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
    ANYTLS_PORT=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .listen_port // empty' "$CONFIG_PATH") || return 1
    ANYTLS_USER=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .users[0].name // empty' "$CONFIG_PATH") || return 1
    ANYTLS_PSK=$(jq -r '.inbounds[] | select(.type=="anytls" and .tls.reality.enabled==true) | .users[0].password // empty' "$CONFIG_PATH") || return 1
fi
}

# 获取公网IP（原始方法）
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    echo "YOUR_SERVER_IP"
}

# 生成并保存URI
generate_uris() {
    read_config || return 1

    # 优先使用用户自定义入口 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        PUBLIC_IP="$CUSTOM_IP"
    else
        PUBLIC_IP=$(get_public_ip)
    fi

    NODE_NAME_FILE="${SINGBOX_NODE_NAME_FILE:-$CONFIG_DIR/node_names.txt}"
    node_suffix=$(cat "$NODE_NAME_FILE" 2>/dev/null || echo "")

    URI_FILE="$CONFIG_DIR/uris.txt"
    local uri_tmp="$URI_FILE.tmp.$$"
    : > "$uri_tmp" || return 1

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        ss_userinfo="${SS_METHOD}:${SS_PSK}"
        ss_encoded=$(url_encode "$ss_userinfo")
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ===" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "ss://${ss_encoded}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "ss://${ss_b64}@${PUBLIC_IP}:${SS_PORT}#ss${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        hy2_encoded=$(url_encode "$HY2_PSK")
        local hy2_fragment hy2_host="$PUBLIC_IP" hy2_authority_port="$HY2_PORT" hy2_mihomo_query=''
        hy2_fragment=$(url_encode "hy2${node_suffix}") || { rm -f "$uri_tmp"; return 1; }
        [[ "$hy2_host" == *:* && "$hy2_host" != \[*\] ]] && hy2_host="[$hy2_host]"
        if [ "$HY2_HOPPING_ENABLED" = true ]; then
            hy2_authority_port="$HY2_HOP_START-$HY2_HOP_END"
            hy2_mihomo_query="&hop-interval=$HY2_HOP_INTERVAL"
        fi
        if [ "$HY2_BRUTAL_ENABLED" = true ]; then
            hy2_mihomo_query+="&up=$HY2_CLIENT_UP_MBPS&down=$HY2_CLIENT_DOWN_MBPS"
        fi
        if [ "${HY2_LEGACY_CONGESTION:-false}" = true ]; then
            echo '提示：旧版 HY2 服务端尚未强制 BBR；进入“配置 HY2”并确认设置后才会规范化。' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        fi
        echo '=== Hysteria2 标准 URI（通用） ===' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "hy2://${hy2_encoded}@${hy2_host}:${hy2_authority_port}/?sni=www.bing.com&alpn=h3&insecure=1#${hy2_fragment}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo '' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo '=== Hysteria2 Shadowrocket URI ===' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        local shadow_query=''
        [ "$HY2_HOPPING_ENABLED" = true ] && shadow_query="mport=$HY2_HOP_START-$HY2_HOP_END&"
        echo "hy2://${hy2_encoded}@${hy2_host}:${HY2_PORT}/?${shadow_query}sni=www.bing.com&alpn=h3&insecure=1#${hy2_fragment}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        if [ "$HY2_HOPPING_ENABLED" = true ] || [ "$HY2_BRUTAL_ENABLED" = true ]; then
            echo '提示：Shadowrocket 请手动核对端口跳跃和/或 Brutal 上下行速率设置。' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        fi
        echo '' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo '=== Hysteria2 Mihomo / mihomo-kit 扩展 URI（非官方扩展） ===' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "hy2://${hy2_encoded}@${hy2_host}:${hy2_authority_port}/?sni=www.bing.com&alpn=h3&insecure=1${hy2_mihomo_query}#${hy2_fragment}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo '' >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        tuic_encoded=$(url_encode "$TUIC_PSK")
        echo "=== TUIC ===" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "tuic://${TUIC_UUID}:${tuic_encoded}@${PUBLIC_IP}:${TUIC_PORT}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
        echo "=== VLESS Reality ===" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        anytls_user_encoded=$(url_encode "$ANYTLS_USER")
        anytls_pass_encoded=$(url_encode "$ANYTLS_PSK")
        echo "=== AnyTLS Reality ===" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "anytls://${anytls_pass_encoded}@${PUBLIC_IP}:${ANYTLS_PORT}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
    fi

    mv "$uri_tmp" "$URI_FILE" || { rm -f "$uri_tmp"; return 1; }
    info "URI 已保存到: $URI_FILE"
}

# 查看URI
