# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "主机安装模式需要 root 权限"
        err "请使用 root 用户运行，或选择 Docker 部署模式"
        exit 1
    fi
}

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."

    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq nftables || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq nftables || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq nftables || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型,尝试继续..."
            ;;
    esac

    info "依赖安装完成"
}

check_docker_deps() {
    local command_name
    if [ "$(uname -s)" != "Linux" ]; then
        err "Docker 部署模式仅支持 Linux 主机"
        exit 1
    fi

    for command_name in curl openssl jq docker; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            err "Docker 部署缺少依赖: $command_name"
            err "请先安装该依赖后，以当前用户重新运行"
            exit 1
        fi
    done

    if docker compose version >/dev/null 2>&1; then
        COMPOSE_KIND="plugin"
    elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
        COMPOSE_KIND="standalone"
    else
        err "未找到 Docker Compose（docker compose 或 docker-compose）"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        err "当前用户无法访问 Docker daemon"
        err "请配置 rootless Docker，或使用已获 Docker daemon 访问权限的用户运行"
        err "注意：加入 rootful Docker 的 docker 组通常等同于获得 root 权限"
        exit 1
    fi

    info "拉取 sing-box Docker 镜像..."
    docker pull "$SINGBOX_IMAGE" || {
        err "Docker 镜像拉取失败: $SINGBOX_IMAGE"
        exit 1
    }
}

docker_compose() {
    if [ "$COMPOSE_KIND" = "plugin" ]; then
        docker compose -f "$CONFIG_DIR/docker-compose.yml" "$@"
    else
        docker-compose -f "$CONFIG_DIR/docker-compose.yml" "$@"
    fi
}

if [ "$DEPLOY_MODE" = "host" ]; then
    check_root
    install_deps
else
    check_docker_deps
fi

