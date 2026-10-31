# -----------------------
# 工具函数
# 生成随机端口
rand_port() {
    local port
    port=$(shuf -i 10000-60000 -n 1 2>/dev/null) || port=$((RANDOM % 50001 + 10000))
    echo "$port"
}

# 生成随机密码
rand_pass() {
    local pass
    pass=$(openssl rand -base64 16 2>/dev/null | tr -d '\n\r') || pass=$(head -c 16 /dev/urandom | base64 2>/dev/null | tr -d '\n\r')
    echo "$pass"
}

# 生成UUID
rand_uuid() {
    local uuid
    if [ -f /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        uuid=$(openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/')
    fi
    echo "$uuid"
}

# -----------------------
# 配置节点名称后缀
echo "请输入节点名称(留空则默认议名):"
read -r user_name
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    mkdir -p "$CONFIG_DIR"
    echo "$suffix" > "$NODE_NAME_FILE"
else
    suffix=""
fi

# -----------------------
# 选择要部署的协议
select_protocols() {
    info "=== 选择要部署的协议 ==="
    echo "1) Shadowsocks (SS)"
    echo "2) Hysteria2 (HY2)"
    echo "3) TUIC"
    echo "4) VLESS Reality"
    echo "5) AnyTLS Reality"
    echo ""
    echo "请输入要部署的协议编号(多个用空格分隔,如: 1 2 4):"
    read -r protocol_input

    # 使用全局变量
    ENABLE_SS=false
    ENABLE_HY2=false
    ENABLE_TUIC=false
    ENABLE_REALITY=false
    ENABLE_ANYTLS=false

    for num in $protocol_input; do
        case "$num" in
            1) ENABLE_SS=true ;;
            2) ENABLE_HY2=true ;;
            3) ENABLE_TUIC=true ;;
            4) ENABLE_REALITY=true ;;
            5) ENABLE_ANYTLS=true ;;
            *) warn "无效选项: $num" ;;
        esac
    done

    if ! $ENABLE_SS && ! $ENABLE_HY2 && ! $ENABLE_TUIC && ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        err "未选择任何协议,退出安装"
        exit 1
    fi

    # 保存协议选择到文件（确保持久化）
    mkdir -p "$CONFIG_DIR"
    cat > "$PROTOCOL_FILE" <<EOF
ENABLE_SS=$ENABLE_SS
ENABLE_HY2=$ENABLE_HY2
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_REALITY=$ENABLE_REALITY
ENABLE_ANYTLS=$ENABLE_ANYTLS
EOF

    info "已选择协议:"
    $ENABLE_SS && echo "  - Shadowsocks"
    $ENABLE_HY2 && echo "  - Hysteria2"
    $ENABLE_TUIC && echo "  - TUIC"
    $ENABLE_REALITY && echo "  - VLESS Reality"
    $ENABLE_ANYTLS && echo "  - AnyTLS Reality"

    # 导出为全局变量（确保后续脚本可以访问）
    export ENABLE_SS
    export ENABLE_HY2
    export ENABLE_TUIC
    export ENABLE_REALITY
    export ENABLE_ANYTLS
}

# 创建配置目录
mkdir -p "$CONFIG_DIR"
select_protocols

# 选择是否启用 sing-box 运行日志
select_log_option() {
    LOG_ENABLED=false
    LOG_DISABLED_JSON=true
    local log_choice=""

    read -r -p "是否启用 sing-box 运行日志? (y/N，默认关闭): " log_choice || log_choice=""
    case "$log_choice" in
        y|Y|yes|YES|Yes)
            LOG_ENABLED=true
            LOG_DISABLED_JSON=false
            ;;
    esac

    if [ "$LOG_ENABLED" = "true" ]; then
        info "运行日志已启用"
    else
        info "运行日志已关闭"
    fi
}

select_log_option

# -----------------------
# 选择SS加密方式（新增）
select_ss_method() {
    if ! $ENABLE_SS; then
        SS_METHOD="2022-blake3-aes-128-gcm"
        return 0
    fi

    info "=== 选择 Shadowsocks 加密方式 ==="
    echo "1) 2022-blake3-aes-128-gcm (推荐)"
    echo "2) aes-128-gcm"
    echo ""
    echo "请输入选择(默认为 1):"
    read -r ss_method_choice

    case "${ss_method_choice:-1}" in
        1) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        2) SS_METHOD="aes-128-gcm" ;;
        *)
            warn "无效选择，使用默认方式: 2022-blake3-aes-128-gcm"
            SS_METHOD="2022-blake3-aes-128-gcm"
            ;;
    esac

    info "已选择加密方式: $SS_METHOD"
    export SS_METHOD
}

select_ss_method

# -----------------------
# 在获取公网 IP 之前，询问连接ip和sni配置
echo ""
echo "请输入节点连接 IP 或 DDNS域名(留空默认出口IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

# 如果用户选择了 Reality 协议，询问 server_name(SNI)
REALITY_SNI=""
if $ENABLE_REALITY || $ENABLE_ANYTLS; then
    echo ""
    echo "请输入 Reality 的 SNI(留空默认 addons.mozilla.org):"
    read -r REALITY_SNI
    REALITY_SNI="$(echo "${REALITY_SNI:-addons.mozilla.org}" | tr -d '[:space:]')"
else
    # 也设默认，方便后续统一处理（若未选 reality，也写入缓存以便 sb 读取）
    REALITY_SNI="addons.mozilla.org"
fi

# 将用户选择写入缓存
mkdir -p "$CONFIG_DIR"
# preserve existing cache if any (append/overwrite relevant keys)
# 最简单直接：在后面 create_config 也会写入 .config_cache，先写初始值以便中间步骤可读取
echo "CUSTOM_IP=$CUSTOM_IP" > "$CACHE_FILE.tmp" || true
echo "REALITY_SNI=$REALITY_SNI" >> "$CACHE_FILE.tmp" || true
# 保留其他可能已有的缓存条目（若存在老的 .config_cache），把新临时与旧文件合并（保新值覆盖旧值）
if [ -f "$CACHE_FILE" ]; then
    # 将旧文件中不在新文件内的行追加
    awk 'FNR==NR{a[$1]=1;next} {split($0,k,"="); if(!(k[1] in a)) print $0}' "$CACHE_FILE.tmp" "$CACHE_FILE" >> "$CACHE_FILE.tmp2" || true
    mv "$CACHE_FILE.tmp2" "$CACHE_FILE.tmp" || true
fi
mv "$CACHE_FILE.tmp" "$CACHE_FILE" || true

# -----------------------
# 生成随机端口
rand_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

# 生成随机密码
rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'
}

# 生成UUID
rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# -----------------------
# HY2 转发方式
normalize_hy2_forward_mode() {
    local mode="${1:-}" hopping="${2:-false}" deploy_mode="${3:-$DEPLOY_MODE}"
    if [ "$deploy_mode" = docker ] || [ "$hopping" != true ]; then
        printf '\n'
        return 0
    fi
    mode="${mode:-nftables}"
    case "$mode" in
        nftables|external) printf '%s\n' "$mode" ;;
        *) err "无效的 HY2 转发方式: $mode"; return 1 ;;
    esac
}

probe_nftables_access() {
    command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1
}

select_hy2_forward_mode() {
    local nft_available=false choice=""
    if probe_nftables_access; then nft_available=true; fi
    while :; do
        echo "选择 HY2 端口跳跃转发方式："
        if [ "$nft_available" = true ]; then
            echo "1) 本机 nftables（需要 root/CAP_NET_ADMIN，可用）"
            read -r -p "2) 外部端口转发（宿主机/NAT 面板负责）[默认 1]: " choice || choice=
            choice="${choice:-1}"
        else
            echo "1) 本机 nftables（需要 root/CAP_NET_ADMIN，不可用）"
            echo "2) 外部端口转发（宿主机/NAT 面板负责）"
            warn "当前环境无法管理 nftables，请明确选择外部转发或输入 q 取消"
            read -r -p "请选择 [2/q]: " choice || choice=q
        fi
        case "$choice" in
            1)
                if [ "$nft_available" = true ]; then
                    HY2_HOPPING_FORWARD_MODE=nftables
                    return 0
                fi
                warn "当前环境 nftables 不可用，请选择外部转发或取消"
                ;;
            2)
                HY2_HOPPING_FORWARD_MODE=external
                return 0
                ;;
            q|Q)
                return 1
                ;;
            *) warn "无效选择，请重新输入" ;;
        esac
    done
}

confirm_external_forwarding() {
    local start="$1" end="$2" answer=""
    echo "需要外部配置：UDP ${start}-${end} -> 容器 UDP ${start}"
    echo "错误示例：${start}-${end}:${start}-${end}/udp（一对一映射无效，除 ${start} 外容器端口无人监听）"
    echo "可配置整个 UDP 范围转发到 ${start}，或逐个外部端口转发到 ${start}。"
    read -r -p "确认已理解并将配置上述多对一转发？[y/N]: " answer || answer=
    [[ "$answer" = y || "$answer" = Y ]]
}

# -----------------------
# 配置端口和密码
get_config() {
    info "开始配置端口和密码..."

    if $ENABLE_SS; then
        info "=== 配置 Shadowsocks (SS) ==="
        if [ -n "${SINGBOX_PORT_SS:-}" ]; then
            PORT_SS="$SINGBOX_PORT_SS"
        else
            read -p "请输入 SS 端口(留空则随机 10000-60000): " USER_PORT_SS
            PORT_SS="${USER_PORT_SS:-$(rand_port)}"
        fi
        PSK_SS=$(rand_pass)
        info "SS 端口: $PORT_SS"
        info "SS 加密方式: $SS_METHOD"
        info "SS 密码已自动生成"
    fi

    if $ENABLE_HY2; then
        info "=== 配置 Hysteria2 (HY2) ==="
        if [ -n "${SINGBOX_PORT_HY2:-}" ]; then
            PORT_HY2="$SINGBOX_PORT_HY2"
        else
            read -p "请输入 HY2 端口(留空则随机 10000-60000): " USER_PORT_HY2
            PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
        fi
        local hop_choice hop_range hop_interval brutal_choice client_up client_down
        [[ "$PORT_HY2" =~ ^[1-9][0-9]{0,4}$ ]] && (( PORT_HY2 <= 65535 )) || { err "HY2 端口必须为 1-65535 的整数"; exit 1; }
        read -r -p "启用 HY2 UDP 端口跳跃? (y/N，默认关闭): " hop_choice || hop_choice=
        HY2_HOPPING_ENABLED=false
        HY2_HOP_START=""
        HY2_HOP_END=""
        HY2_HOP_INTERVAL=15
        HY2_HOPPING_FORWARD_MODE=""
        if [[ "$hop_choice" =~ ^[Yy]$ ]]; then
            while :; do
                read -r -p "输入连续 UDP 端口范围 start-end（2-100 个端口）: " hop_range || hop_range=
                if [[ "$hop_range" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
                    HY2_HOP_START=$((10#${BASH_REMATCH[1]}))
                    HY2_HOP_END=$((10#${BASH_REMATCH[2]}))
                    local count=$((HY2_HOP_END - HY2_HOP_START + 1))
                    if (( HY2_HOP_START >= 1 && HY2_HOP_END <= 65535 && count >= 2 && count <= 100 )); then break; fi
                fi
                warn "范围必须有效且包含 2–100 个连续端口"
            done
            PORT_HY2=$HY2_HOP_START
            read -r -p "跳跃间隔秒数 [15]（5-3600）: " hop_interval || hop_interval=
            HY2_HOP_INTERVAL=${hop_interval:-15}
            [[ "$HY2_HOP_INTERVAL" =~ ^[0-9]+$ ]] || { err "跳跃间隔必须为 5-3600 的整数"; exit 1; }
            HY2_HOP_INTERVAL=$((10#$HY2_HOP_INTERVAL))
            (( HY2_HOP_INTERVAL >= 5 && HY2_HOP_INTERVAL <= 3600 )) || { err "跳跃间隔必须为 5-3600 的整数"; exit 1; }
            HY2_HOPPING_ENABLED=true
            if [ "$DEPLOY_MODE" = host ]; then
                select_hy2_forward_mode || { err "已取消 HY2 转发方式选择，未写入节点配置"; exit 1; }
                if [ "$HY2_HOPPING_FORWARD_MODE" = external ]; then
                    confirm_external_forwarding "$HY2_HOP_START" "$HY2_HOP_END" || { err "未确认外部端口转发，未写入节点配置"; exit 1; }
                fi
            fi
        fi
        read -r -p "启用 Brutal 拥塞控制? (y/N，默认 BBR): " brutal_choice || brutal_choice=
        HY2_BRUTAL_ENABLED=false
        HY2_CLIENT_UP_MBPS=""
        HY2_CLIENT_DOWN_MBPS=""
        if [[ "$brutal_choice" =~ ^[Yy]$ ]]; then
            read -r -p "客户端上行 Mbps（正整数）: " client_up || client_up=
            read -r -p "客户端下行 Mbps（正整数）: " client_down || client_down=
            [[ "$client_up" =~ ^[1-9][0-9]*$ && "$client_down" =~ ^[1-9][0-9]*$ ]] || { err "Brutal 上下行速率必须为正整数"; exit 1; }
            HY2_BRUTAL_ENABLED=true
            HY2_CLIENT_UP_MBPS=$client_up
            HY2_CLIENT_DOWN_MBPS=$client_down
        fi
        PSK_HY2=$(rand_pass)
        info "HY2 监听端口: $PORT_HY2"
        info "HY2 密码已自动生成"
    fi

    if $ENABLE_TUIC; then
        info "=== 配置 TUIC ==="
        if [ -n "${SINGBOX_PORT_TUIC:-}" ]; then
            PORT_TUIC="$SINGBOX_PORT_TUIC"
        else
            read -p "请输入 TUIC 端口(留空则随机 10000-60000): " USER_PORT_TUIC
            PORT_TUIC="${USER_PORT_TUIC:-$(rand_port)}"
        fi
        PSK_TUIC=$(rand_pass)
        UUID_TUIC=$(rand_uuid)
        info "TUIC 端口: $PORT_TUIC"
        info "TUIC UUID 和密码已自动生成"
    fi

    if $ENABLE_REALITY; then
        info "=== 配置 VLESS Reality ==="
        if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
            PORT_REALITY="$SINGBOX_PORT_REALITY"
        else
            read -p "请输入 VLESS Reality 端口(留空则随机 10000-60000): " USER_PORT_REALITY
            PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
        fi
        UUID=$(rand_uuid)
        info "VLESS Reality 端口: $PORT_REALITY"
        info "VLESS Reality UUID 已自动生成"
    fi

    if $ENABLE_ANYTLS; then
    info "=== 配置 AnyTLS Reality ==="
    if [ -n "${SINGBOX_PORT_ANYTLS:-}" ]; then
        PORT_ANYTLS="$SINGBOX_PORT_ANYTLS"
    else
        read -p "请输入 AnyTLS Reality 端口(留空则随机 10000-60000): " USER_PORT_ANYTLS
        PORT_ANYTLS="${USER_PORT_ANYTLS:-$(rand_port)}"
    fi

    ANYTLS_USER=$(openssl rand -hex 4)
    ANYTLS_PSK=$(openssl rand -base64 16)

    info "AnyTLS Reality 端口: $PORT_ANYTLS"
    info "AnyTLS Reality 用户名: $ANYTLS_USER"
    info "AnyTLS Reality 密码已自动生成"
    fi

    info "配置完成，继续安装..."
}

get_config

