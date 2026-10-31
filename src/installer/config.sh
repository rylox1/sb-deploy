create_config() {
    if [ "$DEPLOY_MODE" = host ] && $ENABLE_HY2; then
        HY2_HOPPING_FORWARD_MODE=$(normalize_hy2_forward_mode "${HY2_HOPPING_FORWARD_MODE:-}" "${HY2_HOPPING_ENABLED:-false}" host) || exit 1
        if [ "$HY2_HOPPING_FORWARD_MODE" = nftables ] && ! probe_nftables_access; then
            err "当前环境无法管理 nftables，未写入节点配置"
            exit 1
        fi
    fi
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    # 构建 inbounds 内容（使用临时文件避免字符串处理问题）
    local TEMP_INBOUNDS="/tmp/singbox_inbounds_$.json"
    > "$TEMP_INBOUNDS"

    local need_comma=false

    if $ENABLE_SS; then
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_SS'
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": PORT_SS_PLACEHOLDER,
      "method": "METHOD_SS_PLACEHOLDER",
      "password": "PSK_SS_PLACEHOLDER",
      "tag": "ss-in"
    }
INBOUND_SS
        sed -i "s|PORT_SS_PLACEHOLDER|$PORT_SS|g" "$TEMP_INBOUNDS"
        sed -i "s|METHOD_SS_PLACEHOLDER|$SS_METHOD|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_SS_PLACEHOLDER|$PSK_SS|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_HY2; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_HY2'
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2_PLACEHOLDER,
      "ignore_client_bandwidth": true,
      "users": [
        {
          "password": "PSK_HY2_PLACEHOLDER"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_HY2
        sed -i "s|PORT_HY2_PLACEHOLDER|$PORT_HY2|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_HY2_PLACEHOLDER|$PSK_HY2|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_TUIC; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_TUIC'
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_TUIC_PLACEHOLDER",
          "password": "PSK_TUIC_PLACEHOLDER"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
INBOUND_TUIC
        sed -i "s|PORT_TUIC_PLACEHOLDER|$PORT_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_TUIC_PLACEHOLDER|$UUID_TUIC|g" "$TEMP_INBOUNDS"
        sed -i "s|PSK_TUIC_PLACEHOLDER|$PSK_TUIC|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_REALITY; then
        $need_comma && echo "," >> "$TEMP_INBOUNDS"
        cat >> "$TEMP_INBOUNDS" <<'INBOUND_REALITY'
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_REALITY_PLACEHOLDER,
      "users": [
        {
          "uuid": "UUID_REALITY_PLACEHOLDER",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": ["REALITY_SID_PLACEHOLDER"]
        }
      }
    }
INBOUND_REALITY
        sed -i "s|PORT_REALITY_PLACEHOLDER|$PORT_REALITY|g" "$TEMP_INBOUNDS"
        sed -i "s|UUID_REALITY_PLACEHOLDER|$UUID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
        sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"
        need_comma=true
    fi

    if $ENABLE_ANYTLS; then
    $need_comma && echo "," >> "$TEMP_INBOUNDS"
    cat >> "$TEMP_INBOUNDS" <<'INBOUND_ANYTLS'
    {
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS_PLACEHOLDER,
      "users": [
        {
          "name": "ANYTLS_USER_PLACEHOLDER",
          "password": "ANYTLS_PSK_PLACEHOLDER"
        }
      ],
      "padding_scheme": [],
      "tls": {
        "enabled": true,
        "server_name": "REALITY_SNI_PLACEHOLDER",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "REALITY_SNI_PLACEHOLDER",
            "server_port": 443
          },
          "private_key": "REALITY_PK_PLACEHOLDER",
          "short_id": [
            "REALITY_SID_PLACEHOLDER"
          ]
        }
      }
    }
INBOUND_ANYTLS

    sed -i "s|PORT_ANYTLS_PLACEHOLDER|$PORT_ANYTLS|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_USER_PLACEHOLDER|$ANYTLS_USER|g" "$TEMP_INBOUNDS"
    sed -i "s|ANYTLS_PSK_PLACEHOLDER|$ANYTLS_PSK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_PK_PLACEHOLDER|$REALITY_PK|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SID_PLACEHOLDER|$REALITY_SID|g" "$TEMP_INBOUNDS"
    sed -i "s|REALITY_SNI_PLACEHOLDER|$REALITY_SNI|g" "$TEMP_INBOUNDS"

    need_comma=true
    fi

    # 生成最终配置
    cat > "$CONFIG_PATH" <<'CONFIG_HEAD'
{
  "log": {
    "disabled": __LOG_DISABLED__,
    "level": "info",
    "timestamp": true
  },
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "30m"
  },
  "inbounds": [
CONFIG_HEAD

    cat "$TEMP_INBOUNDS" >> "$CONFIG_PATH"

    cat >> "$CONFIG_PATH" <<'CONFIG_TAIL'
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
CONFIG_TAIL

    sed -i "s/__LOG_DISABLED__/$LOG_DISABLED_JSON/g" "$CONFIG_PATH"
    if $ENABLE_HY2; then
        if [ "${HY2_BRUTAL_ENABLED:-false}" = true ]; then
            jq --argjson up "$HY2_CLIENT_DOWN_MBPS" --argjson down "$HY2_CLIENT_UP_MBPS" '
              .inbounds |= map(if .type=="hysteria2" then . + {ignore_client_bandwidth:true,up_mbps:$up,down_mbps:$down} else . end)
            ' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH" || { err "写入 HY2 Brutal 设置失败"; exit 1; }
        fi
    fi
    rm -f "$TEMP_INBOUNDS"

    if $ENABLE_HY2 && [ "${HY2_HOPPING_ENABLED:-false}" = true ]; then
        jq -e --argjson start "$HY2_HOP_START" --argjson end "$HY2_HOP_END" '
          [.inbounds[]? | select(.listen_port|type=="number") | {type,port:.listen_port,reality:(.tls.reality.enabled==true)}] as $items |
          all($items[]; . as $item |
            if $item.type=="hysteria2" then $item.port==$start
            else
              (if $item.type=="vless" or $item.type=="anytls" then ($item.reality|not)
               else true end) as $udp |
              (($udp|not) or $item.port < $start or $item.port > $end)
            end
          )
        ' "$CONFIG_PATH" >/dev/null || { err "HY2 UDP 跳跃范围与其他 inbound 冲突"; exit 1; }
    fi

    local config_valid=false
    if [ "$DEPLOY_MODE" = "docker" ]; then
        run_singbox check -c /etc/sing-box/config.json >/dev/null 2>&1 && config_valid=true
    else
        run_singbox check -c "$CONFIG_PATH" >/dev/null 2>&1 && config_valid=true
    fi
    if [ "$config_valid" = "true" ]; then
        info "配置文件验证通过"
    else
        warn "配置文件验证失败"
        if [ "$DEPLOY_MODE" = "docker" ]; then
            exit 1
        fi
    fi

    # 保存配置缓存（追加/覆盖）
    cat > "$CACHE_FILE" <<CACHEEOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
LOG_ENABLED=$LOG_ENABLED
CACHEEOF

    $ENABLE_SS && cat >> "$CACHE_FILE" <<CACHEEOF
SS_PORT=$PORT_SS
SS_PSK=$PSK_SS
SS_METHOD=$SS_METHOD
CACHEEOF

    $ENABLE_HY2 && cat >> "$CACHE_FILE" <<CACHEEOF
HY2_PORT=$PORT_HY2
HY2_PSK=$PSK_HY2
HY2_HOPPING_ENABLED=${HY2_HOPPING_ENABLED:-false}
HY2_HOP_START=${HY2_HOP_START:-}
HY2_HOP_END=${HY2_HOP_END:-}
HY2_HOP_INTERVAL=${HY2_HOP_INTERVAL:-15}
HY2_BRUTAL_ENABLED=${HY2_BRUTAL_ENABLED:-false}
HY2_CLIENT_UP_MBPS=${HY2_CLIENT_UP_MBPS:-}
HY2_CLIENT_DOWN_MBPS=${HY2_CLIENT_DOWN_MBPS:-}
CACHEEOF
    if [ "$DEPLOY_MODE" = host ] && $ENABLE_HY2; then
        printf 'HY2_HOPPING_FORWARD_MODE=%s\n' "${HY2_HOPPING_FORWARD_MODE:-}" >> "$CACHE_FILE"
    fi

    $ENABLE_TUIC && cat >> "$CACHE_FILE" <<CACHEEOF
TUIC_PORT=$PORT_TUIC
TUIC_UUID=$UUID_TUIC
TUIC_PSK=$PSK_TUIC
CACHEEOF

    $ENABLE_REALITY && cat >> "$CACHE_FILE" <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
REALITY_SNI=$REALITY_SNI
CACHEEOF

    $ENABLE_ANYTLS && cat >> "$CACHE_FILE" <<CACHEEOF
ANYTLS_PORT=$PORT_ANYTLS
ANYTLS_USER=$ANYTLS_USER
ANYTLS_PSK=$ANYTLS_PSK
CACHEEOF

    # 全局写入 CUSTOM_IP（哪怕为空也写）
    echo "CUSTOM_IP=$CUSTOM_IP" >> "$CACHE_FILE"

    info "配置缓存已保存到 $CACHE_FILE"
}

# 调用配置生成
create_config

info "配置生成完成，准备设置服务..."

# -----------------------
# 生成 Docker Compose 端口配置辅助脚本
