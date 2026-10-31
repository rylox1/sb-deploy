docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        (cd "$CONFIG_DIR" && docker compose -f docker-compose.yml "$@")
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        (cd "$CONFIG_DIR" && docker-compose -f docker-compose.yml "$@")
    else
        err "未找到 Docker Compose（docker compose 或 docker-compose）"
        return 1
    fi
}

refresh_docker_compose() {
    "$CONFIG_DIR/docker-compose-refresh.sh"
}

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

validate_hy2_runtime_prerequisites() {
    if [ "$DEPLOY_MODE" = host ] && [ "${HY2_HOPPING_ENABLED:-false}" = true ] && [ "${HY2_HOPPING_FORWARD_MODE:-nftables}" = nftables ] && ! probe_nftables_access; then
        err 'HY2 nftables 不可用，未修改节点配置'
        return 1
    fi
}

hy2_hopping_service_file() {
    if [ "$OS" = alpine ]; then
        printf '%s\n' /etc/init.d/sb-deploy-hy2-hopping
    else
        printf '%s\n' /etc/systemd/system/sb-deploy-hy2-hopping.service
    fi
}

hy2_hopping_runlevel_file() {
    printf '%s\n' /etc/runlevels/default/sb-deploy-hy2-hopping
}

cleanup_hy2_hopping_runtime() {
    [ "$DEPLOY_MODE" = host ] || return 0
    local force_table="${1:-false}" helper="$CONFIG_DIR/hy2-port-hopping.sh" service_file active=false failed=false unit_removed=false enabled=false temp_exists=false temp_file runlevel_file
    service_file=$(hy2_hopping_service_file) || return 1
    runlevel_file=$(hy2_hopping_runlevel_file) || return 1
    for temp_file in "$helper".tmp.* "$service_file".tmp.*; do
        [ ! -e "$temp_file" ] || temp_exists=true
    done
    if [ "$OS" = alpine ]; then
        if [ ! -e "$helper" ] && [ ! -e "$service_file" ] && [ ! -L "$runlevel_file" ] && [ "$temp_exists" = false ]; then return 0; fi
        if [ -e "$service_file" ] && rc-service sb-deploy-hy2-hopping status >/dev/null 2>&1; then
            active=true
            rc-service sb-deploy-hy2-hopping stop || failed=true
        fi
    else
        if command -v systemctl >/dev/null 2>&1; then
            systemctl is-enabled --quiet sb-deploy-hy2-hopping.service && enabled=true
        elif [ -e "$helper" ] || [ -e "$service_file" ]; then
            err 'systemctl 不可用，无法清理 HY2 跳跃服务'
            return 1
        fi
        if [ ! -e "$helper" ] && [ ! -e "$service_file" ] && [ "$enabled" = false ] && [ "$temp_exists" = false ]; then return 0; fi
        if [ -e "$service_file" ]; then
            systemctl is-active --quiet sb-deploy-hy2-hopping.service && active=true
            if [ "$active" = true ]; then systemctl stop sb-deploy-hy2-hopping.service >/dev/null 2>&1 || failed=true; fi
        fi
    fi
    if [ "$failed" = false ] && { [ "$active" = true ] || [ "$force_table" = true ]; }; then
        if [ -x "$helper" ]; then
            "$helper" clear || failed=true
        elif probe_nftables_access; then
            local tables
            tables=$(nft list tables) || failed=true
            if [ "$failed" = false ] && printf '%s\n' "$tables" | grep -Fxq 'table inet sb_deploy_hy2'; then
                nft delete table inet sb_deploy_hy2 >/dev/null 2>&1 || failed=true
            fi
        else
            failed=true
        fi
    fi
    if [ "$failed" = false ]; then
        if [ "$OS" = alpine ]; then
            [ ! -L "$runlevel_file" ] || rc-update del sb-deploy-hy2-hopping default >/dev/null 2>&1 || failed=true
        elif [ "$enabled" = true ] || [ -e "$service_file" ]; then
            systemctl disable sb-deploy-hy2-hopping.service >/dev/null 2>&1 || failed=true
        fi
    fi
    if [ "$failed" = false ]; then
        [ ! -e "$service_file" ] || unit_removed=true
        local path
        for path in "$service_file" "$helper" "$runlevel_file" "$service_file".tmp.* "$helper".tmp.*; do
            [ -e "$path" ] || [ -L "$path" ] || continue
            rm -f "$path" || failed=true
        done
    fi
    if [ "$OS" != alpine ] && [ "$unit_removed" = true ]; then systemctl daemon-reload >/dev/null 2>&1 || failed=true; fi
    if [ "$failed" = true ]; then
        err '清理 HY2 跳跃运行时失败；请人工检查 sb-deploy-hy2-hopping 服务及 inet sb_deploy_hy2 表'
        return 1
    fi
}

clear_hy2_hopping_runtime() {
    cleanup_hy2_hopping_runtime
}

rollback_hy2_hopping_runtime() {
    cleanup_hy2_hopping_runtime true || { err 'HY2 跳跃运行时回滚不完整'; return 1; }
}

reconcile_hy2_hopping_runtime() {
    [ "$DEPLOY_MODE" = host ] || return 0
    local mode="${HY2_HOPPING_FORWARD_MODE:-}"
    if [ "${ENABLE_HY2:-false}" != true ] || [ "${HY2_HOPPING_ENABLED:-false}" != true ]; then
        cleanup_hy2_hopping_runtime
        return $?
    fi
    mode=$(normalize_hy2_forward_mode "$mode" true host) || return 1
    if [ "$mode" = external ]; then cleanup_hy2_hopping_runtime; return $?; fi
    probe_nftables_access || { err 'HY2 nftables 不可用，未创建跳跃运行时'; return 1; }
    ensure_hy2_hopping_runtime || { rollback_hy2_hopping_runtime; return 1; }
}

ensure_hy2_hopping_runtime() {
    [ "$DEPLOY_MODE" = host ] || return 0
    local helper="$CONFIG_DIR/hy2-port-hopping.sh" service_file helper_tmp service_tmp
    service_file=$(hy2_hopping_service_file) || return 1
    helper_tmp="$helper.tmp.$$"
    service_tmp="$service_file.tmp.$$"
    cat > "$helper_tmp" <<'HOPPING_SCRIPT' || return 1
#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cache_value() { awk -F= -v key="$1" '$1==key {sub(/^[^=]*=/, ""); print; exit}' "$CONFIG_DIR/.config_cache" 2>/dev/null || true; }
clear_rules() {
  local tables
  tables=$(nft list tables) || return 1
  if printf '%s\n' "$tables" | grep -Fxq 'table inet sb_deploy_hy2'; then
    nft delete table inet sb_deploy_hy2
  fi
}
apply_rules() {
  local start="$1" end="$2" port="$3" tables
  tables=$(nft list tables) || return 1
  {
    if printf '%s\n' "$tables" | grep -Fxq 'table inet sb_deploy_hy2'; then
      printf '%s\n' 'delete table inet sb_deploy_hy2'
    fi
    printf '%s\n' \
      'add table inet sb_deploy_hy2' \
      'add chain inet sb_deploy_hy2 prerouting { type nat hook prerouting priority dstnat; policy accept; }'
    printf 'add rule inet sb_deploy_hy2 prerouting udp dport %s-%s redirect to :%s\n' "$start" "$end" "$port"
  } | nft -f -
}
case "${1:-}" in
  clear) clear_rules ;;
  apply)
    enabled=$(cache_value HY2_HOPPING_ENABLED)
    if [ "$enabled" != true ]; then clear_rules; exit 0; fi
    start=$(cache_value HY2_HOP_START); end=$(cache_value HY2_HOP_END); interval=$(cache_value HY2_HOP_INTERVAL)
    port=$(jq -er '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$CONFIG_DIR/config.json")
    [[ "$start" =~ ^[0-9]{1,5}$ && "$end" =~ ^[0-9]{1,5}$ && "$interval" =~ ^[0-9]{1,4}$ ]] || { echo '[ERR] HY2 跳跃缓存无效' >&2; exit 1; }
    start=$((10#$start)); end=$((10#$end)); interval=$((10#$interval)); count=$((end-start+1))
    (( start >= 1 && end <= 65535 && start == port && count >= 2 && count <= 100 && interval >= 5 && interval <= 3600 )) || { echo '[ERR] HY2 跳跃配置校验失败' >&2; exit 1; }
    command -v nft >/dev/null 2>&1 || { echo '[ERR] 启用 HY2 跳跃需要 nftables' >&2; exit 1; }
    apply_rules "$start" "$end" "$port"
    ;;
  *) echo '用法: hy2-port-hopping.sh apply|clear' >&2; exit 2 ;;
esac
HOPPING_SCRIPT
    chmod 700 "$helper_tmp" && mv "$helper_tmp" "$helper" || return 1
    if [ "$OS" = alpine ]; then
        cat > "$service_tmp" <<'OPENRC_HOP' || return 1
#!/sbin/openrc-run
name="sb-deploy-hy2-hopping"
command="/etc/sing-box/hy2-port-hopping.sh"
command_args="apply"
depend() { need net; before sing-box; }
start() { "$command" apply; }
stop() { "$command" clear; }
OPENRC_HOP
        chmod +x "$service_tmp" && mv "$service_tmp" "$service_file" || return 1
        rc-update add sb-deploy-hy2-hopping default >/dev/null 2>&1 || return 1
        rc-service sb-deploy-hy2-hopping restart || return 1
    else
        cat > "$service_tmp" <<'SYSTEMD_HOP' || return 1
[Unit]
Description=sb-deploy HY2 UDP port hopping
Before=sing-box.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/sing-box/hy2-port-hopping.sh apply
ExecStop=/etc/sing-box/hy2-port-hopping.sh clear
[Install]
WantedBy=multi-user.target
SYSTEMD_HOP
        mv "$service_tmp" "$service_file" || return 1
        systemctl daemon-reload || return 1
        systemctl enable sb-deploy-hy2-hopping.service >/dev/null 2>&1 || return 1
        systemctl restart sb-deploy-hy2-hopping.service || return 1
    fi
}

# 服务控制
service_start() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        refresh_docker_compose && docker_compose config >/dev/null && docker_compose up -d
    else
        read_config || return 1
        reconcile_hy2_hopping_runtime || return 1
        if [ "$OS" = "alpine" ]; then rc-service "$SERVICE_NAME" start; else systemctl start "$SERVICE_NAME"; fi
    fi
}
service_stop() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        docker_compose stop
    elif [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" stop
    else
        systemctl stop "$SERVICE_NAME"
    fi
}
service_restart() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        refresh_docker_compose && docker_compose config >/dev/null && docker_compose up -d --force-recreate
    else
        read_config || return 1
        reconcile_hy2_hopping_runtime || return 1
        if [ "$OS" = "alpine" ]; then rc-service "$SERVICE_NAME" restart; else systemctl restart "$SERVICE_NAME"; fi
    fi
}
service_status() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        docker_compose ps
    elif [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" status
    else
        systemctl status "$SERVICE_NAME" --no-pager
    fi
}

run_singbox() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        docker run --rm \
            --volume "$CONFIG_DIR:/etc/sing-box:ro" \
            --entrypoint sing-box ghcr.io/sagernet/sing-box:latest "$@"
    else
        sing-box "$@"
    fi
}

validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
        err "端口必须是 1-65535 的整数: $port"
        return 1
    fi
}

# 生成随机值
rand_port() { shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)); }
rand_pass() { openssl rand -base64 16 | tr -d '\n\r' || head -c 16 /dev/urandom | base64 | tr -d '\n\r'; }
rand_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'; }

# URL 编码
url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

# 读取配置
