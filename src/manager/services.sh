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

validate_hy2_runtime_prerequisites() {
    local previous_hopping="${1:-false}"
    if [ "$DEPLOY_MODE" = host ] && { [ "${HY2_HOPPING_ENABLED:-false}" = true ] || [ "$previous_hopping" = true ]; } && ! command -v nft >/dev/null 2>&1; then
        err '启用 HY2 端口跳跃需要 nftables；请安装后重试，节点配置未修改'
        return 1
    fi
}

ensure_hy2_hopping_runtime() {
    [ "$DEPLOY_MODE" = host ] || return 0
    local helper="$CONFIG_DIR/hy2-port-hopping.sh"
    cat > "$helper" <<'HOPPING_SCRIPT'
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
    chmod 700 "$helper" || return 1
    if [ "$OS" = alpine ]; then
        cat > /etc/init.d/sb-deploy-hy2-hopping <<'OPENRC_HOP'
#!/sbin/openrc-run
name="sb-deploy-hy2-hopping"
command="/etc/sing-box/hy2-port-hopping.sh"
command_args="apply"
depend() { need net; before sing-box; }
start() { "$command" apply; }
stop() { "$command" clear; }
OPENRC_HOP
        chmod +x /etc/init.d/sb-deploy-hy2-hopping || return 1
        rc-update add sb-deploy-hy2-hopping default >/dev/null 2>&1 || true
        rc-service sb-deploy-hy2-hopping restart || return 1
    else
        cat > /etc/systemd/system/sb-deploy-hy2-hopping.service <<'SYSTEMD_HOP'
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
        systemctl daemon-reload || return 1
        systemctl enable sb-deploy-hy2-hopping.service >/dev/null 2>&1 || return 1
        systemctl restart sb-deploy-hy2-hopping.service || return 1
    fi
}

hy2_hopping_service_file() {
    if [ "$OS" = alpine ]; then
        printf '%s\n' /etc/init.d/sb-deploy-hy2-hopping
    else
        printf '%s\n' /etc/systemd/system/sb-deploy-hy2-hopping.service
    fi
}

clear_hy2_hopping_runtime() {
    [ "$DEPLOY_MODE" = host ] || return 0
    [ ! -x "$CONFIG_DIR/hy2-port-hopping.sh" ] || "$CONFIG_DIR/hy2-port-hopping.sh" clear || return 1
    if [ "$OS" = alpine ]; then
        rc-service sb-deploy-hy2-hopping stop >/dev/null 2>&1 || true
        rc-update del sb-deploy-hy2-hopping default >/dev/null 2>&1 || true
        rm -f /etc/init.d/sb-deploy-hy2-hopping
    else
        systemctl disable --now sb-deploy-hy2-hopping.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sb-deploy-hy2-hopping.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -f "$CONFIG_DIR/hy2-port-hopping.sh"
}

# 服务控制
service_start() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        refresh_docker_compose && docker_compose config >/dev/null && docker_compose up -d
    elif [ -x "$CONFIG_DIR/hy2-port-hopping.sh" ]; then
        "$CONFIG_DIR/hy2-port-hopping.sh" apply || return 1
        if [ "$OS" = alpine ]; then rc-service "$SERVICE_NAME" start; else systemctl start "$SERVICE_NAME"; fi
    elif [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" start
    else
        systemctl start "$SERVICE_NAME"
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
    elif [ -x "$CONFIG_DIR/hy2-port-hopping.sh" ]; then
        "$CONFIG_DIR/hy2-port-hopping.sh" apply || return 1
        if [ "$OS" = alpine ]; then rc-service "$SERVICE_NAME" restart; else systemctl restart "$SERVICE_NAME"; fi
    elif [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" restart
    else
        systemctl restart "$SERVICE_NAME"
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
