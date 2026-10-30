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

# 服务控制
service_start() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        refresh_docker_compose && docker_compose up -d
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
        refresh_docker_compose && docker_compose up -d --force-recreate
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
    printf "%s" "$1" | sed -e 's/%/%25/g' -e 's/:/%3A/g' -e 's/+/%2B/g' -e 's/\//%2F/g' -e 's/=/%3D/g'
}

# 读取配置
