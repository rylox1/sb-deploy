action_view_uri() {
    info "正在生成并显示 URI..."
    generate_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    cat "$CONFIG_DIR/uris.txt"
}

# 查看配置文件路径
action_view_config() {
    echo "$CONFIG_PATH"
}

# 编辑配置
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi

    ${EDITOR:-nano} "$CONFIG_PATH" 2>/dev/null || ${EDITOR:-vi} "$CONFIG_PATH"

    local config_valid=false
    if [ "$DEPLOY_MODE" = "docker" ]; then
        run_singbox check -c /etc/sing-box/config.json >/dev/null 2>&1 && config_valid=true
    elif command -v sing-box >/dev/null 2>&1; then
        run_singbox check -c "$CONFIG_PATH" >/dev/null 2>&1 && config_valid=true
    fi

    if [ "$config_valid" = "true" ]; then
        info "配置校验通过,已重启服务"
        service_restart || warn "重启失败"
        generate_uris || true
    elif [ "$DEPLOY_MODE" = "docker" ] || command -v sing-box >/dev/null 2>&1; then
        warn "配置校验失败,服务未重启"
    fi
}

# 重置SS端口
action_reset_ss() {
    read_config || return 1

    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "SS 协议未启用"
        return 1
    fi

    read -p "输入新的 SS 端口(回车保持 $SS_PORT): " new_port
    new_port="${new_port:-$SS_PORT}"
    validate_port "$new_port" || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="shadowsocks" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 SS 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 配置 HY2 端口跳跃与拥塞控制
action_configure_hy2() {
    read_config || return 1
    [ "${ENABLE_HY2:-false}" = true ] || { err 'HY2 协议未启用'; return 1; }
    local new_port candidate
    read -r -p "输入 HY2 固定端口或跳跃范围首端（回车保持 ${HY2_PORT}）:" new_port || new_port=
    new_port=${new_port:-$HY2_PORT}
    validate_port "$new_port" || return 1
    collect_hy2_settings "$new_port" || return 1
    [ "${HY2_SETTINGS_CANCELLED:-false}" = false ] || return 0
    validate_hy2_runtime_prerequisites || return 1
    candidate=$(mktemp "$CONFIG_DIR/.hy2-configure.XXXXXX") || return 1
    jq --argjson port "$HY2_PORT" --argjson brutal "$HY2_BRUTAL_ENABLED" --argjson up "${HY2_CLIENT_DOWN_MBPS:-0}" --argjson down "${HY2_CLIENT_UP_MBPS:-0}" '
      .inbounds |= map(if .type=="hysteria2" then
        .listen_port=$port | .ignore_client_bandwidth=true |
        (if $brutal then .up_mbps=$up | .down_mbps=$down else del(.up_mbps,.down_mbps) end)
        else . end)
    ' "$CONFIG_PATH" > "$candidate" || { rm -f "$candidate"; return 1; }
    validate_candidate_ports "$candidate" || { rm -f "$candidate"; return 1; }
    if [ "$HY2_HOPPING_ENABLED" = true ]; then
        validate_hy2_hopping_settings "$HY2_HOP_START" "$HY2_HOP_END" "$HY2_HOP_INTERVAL" "$HY2_PORT" || { rm -f "$candidate"; return 1; }
        validate_hy2_port_conflicts "$candidate" "$HY2_HOP_START" "$HY2_HOP_END" || { rm -f "$candidate"; return 1; }
    fi
    local protocol_candidate="$CONFIG_DIR/.hy2-protocols.$$" cache_candidate="$CONFIG_DIR/.hy2-cache.$$"
    render_protocol_state "$candidate" "$protocol_candidate" "$cache_candidate" || { rm -f "$candidate" "$protocol_candidate" "$cache_candidate"; return 1; }
    echo "HY2 监听端口: ${HY2_PORT}"
    if [ "$HY2_HOPPING_ENABLED" = true ]; then
        echo "UDP 跳跃范围: ${HY2_HOP_START}-${HY2_HOP_END}，间隔 ${HY2_HOP_INTERVAL} 秒（防火墙及云安全组需放行完整范围）"
        if [ "$DEPLOY_MODE" = host ]; then
            echo "HY2 转发方式：${HY2_HOPPING_FORWARD_MODE:-nftables}"
            if [ "${HY2_HOPPING_FORWARD_MODE:-nftables}" = external ]; then
                echo "需要外部配置：UDP ${HY2_HOP_START}-${HY2_HOP_END} -> 容器 UDP ${HY2_HOP_START}"
                echo "错误示例：${HY2_HOP_START}-${HY2_HOP_END}:${HY2_HOP_START}-${HY2_HOP_END}/udp（一对一映射无效，除 ${HY2_HOP_START} 外容器端口无人监听）"
                echo "可配置整个 UDP 范围转发到 ${HY2_HOP_START}，或逐个外部端口转发到 ${HY2_HOP_START}。"
                echo '脚本无法验证宿主机规则，请从容器外测试范围首端、中间端和末端。'
            fi
        fi
    else
        echo 'UDP 跳跃: 关闭'
    fi
    if [ "$HY2_BRUTAL_ENABLED" = true ]; then echo "Brutal: 客户端上行 ${HY2_CLIENT_UP_MBPS} Mbps / 下行 ${HY2_CLIENT_DOWN_MBPS} Mbps"; else echo '拥塞控制: BBR（服务端强制）'; fi
    read -r -p '确认应用 HY2 设置？[y/N] ' confirm || confirm=
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then rm -f "$candidate" "$protocol_candidate" "$cache_candidate"; info '已取消，未修改节点配置'; return 0; fi
    TX_DIR=$(mktemp -d "$CONFIG_DIR/.protocol-update.XXXXXX") || return 1
    chmod 700 "$TX_DIR" && mkdir "$TX_DIR/material" || { rm -rf "$TX_DIR"; TX_DIR=; return 1; }
    cp "$candidate" "$TX_DIR/candidate.json" && cp "$protocol_candidate" "$TX_DIR/protocols" && cp "$cache_candidate" "$TX_DIR/cache" || { rm -f "$candidate" "$protocol_candidate" "$cache_candidate"; rm -rf "$TX_DIR"; TX_DIR=; return 1; }
    rm -f "$candidate" "$protocol_candidate" "$cache_candidate"
    if ! apply_protocol_transaction "$TX_DIR/candidate.json" "$TX_DIR/protocols" "$TX_DIR/cache" "$TX_DIR/uri-backup"; then
        rm -rf "$TX_DIR"; TX_DIR=
        return 1
    fi
    rm -rf "$TX_DIR"; TX_DIR=
    read_config || return 1
    info 'HY2 设置已更新'
}

action_reset_hy2() { action_configure_hy2 "$@"; }

# 重置TUIC端口
action_reset_tuic() {
    read_config || return 1

    if [ "${ENABLE_TUIC:-false}" != "true" ]; then
        err "TUIC 协议未启用"
        return 1
    fi

    read -p "输入新的 TUIC 端口(回车保持 $TUIC_PORT): " new_port
    new_port="${new_port:-$TUIC_PORT}"
    validate_port "$new_port" || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="tuic" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 TUIC 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置Vless Reality端口
action_reset_reality() {
    read_config || return 1

    if [ "${ENABLE_REALITY:-false}" != "true" ]; then
        err "Vless Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 Vless Reality 端口(回车保持 $REALITY_PORT): " new_port
    new_port="${new_port:-$REALITY_PORT}"
    validate_port "$new_port" || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="vless" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 Vless Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 重置AnyTLS Reality端口
action_reset_anytls() {
    read_config || return 1

    if [ "${ENABLE_ANYTLS:-false}" != "true" ]; then
        err "AnyTLS Reality 协议未启用"
        return 1
    fi

    read -p "输入新的 AnyTLS Reality 端口(回车保持 $ANYTLS_PORT): " new_port
    new_port="${new_port:-$ANYTLS_PORT}"
    validate_port "$new_port" || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="anytls" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 AnyTLS Reality 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

# 更新sing-box
action_update() {
    info "开始更新 sing-box..."
    if [ "$DEPLOY_MODE" = "docker" ]; then
        docker_compose pull && service_restart || {
            err "Docker 镜像更新或容器重启失败"
            return 1
        }
        info "Docker 镜像更新完成"
        return 0
    fi

    if [ "$OS" = "alpine" ]; then
        apk update && apk upgrade sing-box || bash <(curl -fsSL https://sing-box.app/install.sh)
    else
        bash <(curl -fsSL https://sing-box.app/install.sh)
    fi

    info "更新完成,已重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1)
        info "当前版本: $NEW_VER"
        service_restart || warn "重启失败"
    fi
}

# 卸载
action_uninstall() {
    read -p "确认卸载 sing-box?(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && info "已取消" && return 0

    info "正在卸载..."
    if [ "$DEPLOY_MODE" = host ]; then
        clear_hy2_hopping_runtime || { err '无法清理 HY2 专属 nftables 规则；保留配置以便重试'; return 1; }
    fi
    service_stop || true
    if [ "$DEPLOY_MODE" = "docker" ]; then
        if ! docker_compose down; then
            err "无法移除 Docker 容器，已保留配置和管理入口，请恢复 Docker daemon 后重试"
            return 1
        fi
        rm -rf "$CONFIG_DIR" "$SB_ENTRY_PATH" 2>/dev/null || true
        info "Docker 部署及其配置已卸载"
        return 0
    fi

    if [ "$OS" = "alpine" ]; then
        rc-update del sing-box default 2>/dev/null || true
        rm -f /etc/init.d/sing-box
        apk del sing-box 2>/dev/null || true
    else
        systemctl stop sing-box 2>/dev/null || true
        systemctl disable sing-box 2>/dev/null || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null || true
        apt purge -y sing-box >/dev/null 2>&1 || true
    fi
    rm -rf "$CONFIG_DIR" /var/log/sing-box* "$SB_ENTRY_PATH" /usr/bin/sing-box /root/node_names.txt 2>/dev/null || true
    rm -f /usr/bin/sb 2>/dev/null || true
    info "卸载完成"
}

# 生成线路机脚本
