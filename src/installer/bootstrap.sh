#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 选择部署方式
select_deploy_mode() {
    case "${1:-}" in
        --docker) DEPLOY_MODE="docker" ;;
        --host) DEPLOY_MODE="host" ;;
        "") DEPLOY_MODE="${SINGBOX_DEPLOY_MODE:-}" ;;
        *)
            err "未知参数: $1"
            err "用法: $0 [--host|--docker]"
            exit 1
            ;;
    esac

    if [ -z "$DEPLOY_MODE" ]; then
        echo "请选择部署方式:"
        echo "1) 主机安装 (需要 root)"
        echo "2) Docker 部署 (可普通用户运行，需有 Docker 权限)"
        read -r -p "请选择 [1/2，默认 1]: " deploy_choice || deploy_choice=""
        case "$deploy_choice" in
            2) DEPLOY_MODE="docker" ;;
            ""|1) DEPLOY_MODE="host" ;;
            *) err "无效的部署方式: $deploy_choice"; exit 1 ;;
        esac
    fi

    case "$DEPLOY_MODE" in
        host|docker) ;;
        *) err "SINGBOX_DEPLOY_MODE 仅支持 host 或 docker"; exit 1 ;;
    esac

    if [ "$DEPLOY_MODE" = "docker" ]; then
        CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/sing-box"
        NODE_NAME_FILE="$CONFIG_DIR/node_names.txt"
        SB_PATH="$HOME/.local/bin/sb"
        SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:latest"
        umask 077
    else
        CONFIG_DIR="/etc/sing-box"
        SB_PATH="/usr/local/bin/sb"
        NODE_NAME_FILE="/root/node_names.txt"
    fi

    CONFIG_PATH="$CONFIG_DIR/config.json"
    CACHE_FILE="$CONFIG_DIR/.config_cache"
    PROTOCOL_FILE="$CONFIG_DIR/.protocols"
}

