get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# 如果用户提供了 CUSTOM_IP，则优先使用；否则自动检测出口 IP
if [ -n "${CUSTOM_IP:-}" ]; then
    PUB_IP="$CUSTOM_IP"
    info "使用用户提供的连接IP或ddns域名 : $PUB_IP"
else
    PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
    if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
        warn "无法获取公网 IP,请手动替换"
    else
        info "检测到公网 IP: $PUB_IP"
    fi
fi

# -----------------------
# 生成链接(仅生成已选择的协议)
generate_uris() {
    local host="$PUB_IP"

    if $ENABLE_SS; then
        local ss_userinfo="${SS_METHOD}:${PSK_SS}"
        ss_encoded=$(printf "%s" "$ss_userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        ss_b64=$(printf "%s" "$ss_userinfo" | base64 -w0 2>/dev/null || printf "%s" "$ss_userinfo" | base64 | tr -d '\n')

        echo "=== Shadowsocks (SS) ==="
        echo "ss://${ss_encoded}@${host}:${PORT_SS}#ss${suffix}"
        echo "ss://${ss_b64}@${host}:${PORT_SS}#ss${suffix}"
        echo ""
    fi

    if $ENABLE_HY2; then
        hy2_encoded=$(printf '%s' "$PSK_HY2" | jq -sRr @uri)
        local hy2_fragment hy2_host="$host" authority_port="$PORT_HY2" mihomo_query="" shadow_query=""
        hy2_fragment=$(printf '%s' "hy2${suffix}" | jq -sRr @uri) || return 1
        [[ "$hy2_host" == *:* && "$hy2_host" != \[*\] ]] && hy2_host="[$hy2_host]"
        if [ "${HY2_HOPPING_ENABLED:-false}" = true ]; then
            authority_port="$HY2_HOP_START-$HY2_HOP_END"
            mihomo_query="&hop-interval=$HY2_HOP_INTERVAL"
            shadow_query="mport=$HY2_HOP_START-$HY2_HOP_END&"
        fi
        if [ "${HY2_BRUTAL_ENABLED:-false}" = true ]; then
            mihomo_query+="&up=$HY2_CLIENT_UP_MBPS&down=$HY2_CLIENT_DOWN_MBPS"
        fi
        echo "=== Hysteria2 标准 URI（通用） ==="
        echo "hy2://${hy2_encoded}@${hy2_host}:${authority_port}/?sni=www.bing.com&alpn=h3&insecure=1#${hy2_fragment}"
        echo ""
        echo "=== Hysteria2 Shadowrocket URI ==="
        echo "hy2://${hy2_encoded}@${hy2_host}:${PORT_HY2}/?${shadow_query}sni=www.bing.com&alpn=h3&insecure=1#${hy2_fragment}"
        if [ "${HY2_HOPPING_ENABLED:-false}" = true ] || [ "${HY2_BRUTAL_ENABLED:-false}" = true ]; then
            echo "提示：Shadowrocket 请手动核对端口跳跃和/或 Brutal 上下行速率设置。"
        fi
        echo ""
        echo "=== Hysteria2 Mihomo / mihomo-kit 扩展 URI（非官方扩展） ==="
        echo "hy2://${hy2_encoded}@${hy2_host}:${authority_port}/?sni=www.bing.com&alpn=h3&insecure=1${mihomo_query}#${hy2_fragment}"
        if [ "$DEPLOY_MODE" = host ] && [ "${HY2_HOPPING_ENABLED:-false}" = true ] && [ "${HY2_HOPPING_FORWARD_MODE:-nftables}" = external ]; then
            echo ''
            echo "# 外部转发契约：UDP ${HY2_HOP_START}-${HY2_HOP_END} -> 容器 UDP ${HY2_HOP_START}"
            echo "# 配置整个 UDP 范围到单端口，或逐个外部 UDP 端口映射到容器 UDP ${HY2_HOP_START}。"
            echo "# 不要使用 ${HY2_HOP_START}-${HY2_HOP_END}:${HY2_HOP_START}-${HY2_HOP_END}/udp 一对一映射；范围内只有首端在容器中监听。"
            echo "# 脚本无法验证宿主机规则，请从容器外测试范围首端、中间端和末端。"
        fi
        echo ""
    fi

    if $ENABLE_TUIC; then
        tuic_encoded=$(printf "%s" "$PSK_TUIC" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== TUIC ==="
        echo "tuic://${UUID_TUIC}:${tuic_encoded}@${host}:${PORT_TUIC}/?congestion_control=bbr&alpn=h3&sni=www.bing.com&insecure=1#tuic${suffix}"
        echo ""
    fi

    if $ENABLE_REALITY; then
        echo "=== VLESS Reality ==="
        echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
        echo ""
    fi

    if $ENABLE_ANYTLS; then
        anytls_user_encoded=$(printf "%s" "$ANYTLS_USER" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        anytls_pass_encoded=$(printf "%s" "$ANYTLS_PSK" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== AnyTLS Reality ==="
        echo "anytls://${anytls_pass_encoded}@${host}:${PORT_ANYTLS}/?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#anytls${suffix}"
        echo ""
    fi
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成!"
echo "=========================================="
echo ""
info "📋 配置信息:"
$ENABLE_SS && echo "   SS 端口: $PORT_SS | 密码: $PSK_SS | 加密: $SS_METHOD"
$ENABLE_HY2 && {
    echo "   HY2 监听端口: $PORT_HY2 | 密码: $PSK_HY2"
    if [ "${HY2_HOPPING_ENABLED:-false}" = true ]; then
        echo "   HY2 UDP 放行范围: $HY2_HOP_START-$HY2_HOP_END | 跳跃间隔: ${HY2_HOP_INTERVAL}s（请在主机防火墙和云安全组放行完整范围）"
        if [ "$DEPLOY_MODE" = docker ]; then
            echo "   HY2 端口映射: Docker Compose 管理"
        elif [ "${HY2_HOPPING_FORWARD_MODE:-nftables}" = external ]; then
            echo "   外部转发契约: UDP $HY2_HOP_START-$HY2_HOP_END → 容器 UDP $HY2_HOP_START"
            echo "   请使用范围到单端口或逐条多对一映射；${HY2_HOP_START}-${HY2_HOP_END}:${HY2_HOP_START}-${HY2_HOP_END}/udp 一对一映射无效。"
            echo "   脚本无法验证外部规则，请从容器外测试范围首端、中间端和末端。"
        fi
    fi
    if [ "${HY2_BRUTAL_ENABLED:-false}" = true ]; then
        echo "   HY2 拥塞控制: Brutal（客户端上行 ${HY2_CLIENT_UP_MBPS} Mbps / 下行 ${HY2_CLIENT_DOWN_MBPS} Mbps）"
    else
        echo "   HY2 拥塞控制: BBR（服务端强制）"
    fi
}
$ENABLE_TUIC && echo "   TUIC 端口: $PORT_TUIC | UUID: $UUID_TUIC | 密码: $PSK_TUIC"
$ENABLE_REALITY && echo "   Reality 端口: $PORT_REALITY | UUID: $UUID"
$ENABLE_ANYTLS && echo "   AnyTLS 端口: $PORT_ANYTLS | 用户: $ANYTLS_USER | 密码: $ANYTLS_PSK"
echo "   服务器: $PUB_IP"
echo "   Reality server_name(SNI): ${REALITY_SNI:-addons.mozilla.org}"
if [ "$LOG_ENABLED" = "true" ]; then
    echo "   运行日志: 已开启"
else
    echo "   运行日志: 已关闭（排障时请重新运行安装器并开启）"
fi
echo ""
info "📂 文件位置:"
echo "   配置: $CONFIG_PATH"
($ENABLE_HY2 || $ENABLE_TUIC) && echo "   证书: $CONFIG_DIR/certs/"
echo "   服务: $SERVICE_PATH"
echo ""
info "📜 客户端链接:"
generate_uris > "$CONFIG_DIR/uris.txt.tmp" && mv "$CONFIG_DIR/uris.txt.tmp" "$CONFIG_DIR/uris.txt"
while IFS= read -r line; do
    echo "   $line"
done < "$CONFIG_DIR/uris.txt"
echo ""
info "🔧 管理命令:"
if [ "$DEPLOY_MODE" = "docker" ]; then
    echo "   管理面板: $SB_PATH"
    echo "   启动/停止/重启/状态: 运行 sb 后在菜单中选择"
    if [ "$COMPOSE_KIND" = "plugin" ]; then
        echo "   日志: docker compose -f '$SERVICE_PATH' logs -f"
    else
        echo "   日志: docker-compose -f '$SERVICE_PATH' logs -f"
    fi
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) echo "   提示: 如需直接输入 sb，请将 $HOME/.local/bin 加入 PATH" ;;
    esac
elif [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    if [ "$LOG_ENABLED" = "true" ]; then
        echo "   日志: tail -f /var/log/sing-box.log"
    else
        echo "   日志: 已关闭"
    fi
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    if [ "$LOG_ENABLED" = "true" ]; then
        echo "   日志: journalctl -u sing-box -f"
    else
        echo "   日志: 已关闭"
    fi
fi
echo ""
echo "=========================================="

create_manager
