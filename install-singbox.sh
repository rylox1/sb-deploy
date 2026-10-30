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

main() {
select_deploy_mode "${1:-}"

    if [ -f "$CONFIG_PATH" ]; then
        echo "检测到已有 sing-box 配置: $CONFIG_PATH"
        echo "1) 安全更新管理器并调整协议（默认）"
        echo "2) 明确重新安装并重建配置"
        read -r -p "请选择 [1/2，默认 1]: " existing_choice || existing_choice=""
        case "$existing_choice" in
            ""|1)
                for command_name in bash jq openssl; do
                    command -v "$command_name" >/dev/null 2>&1 || { err "安全更新缺少依赖: $command_name"; return 1; }
                done
                if [ "$DEPLOY_MODE" = "host" ]; then
                    [ "$(id -u)" = "0" ] || { err "主机安装模式需要 root 权限"; return 1; }
                    command -v sing-box >/dev/null 2>&1 || { err "未找到 sing-box，不能安全校验配置"; return 1; }
                else
                    for command_name in docker; do
                        command -v "$command_name" >/dev/null 2>&1 || { err "Docker 模式缺少依赖: $command_name"; return 1; }
                    done
                    docker compose version >/dev/null 2>&1 || { command -v docker-compose >/dev/null 2>&1 || { err "未找到 Docker Compose"; return 1; }; }
                    docker info >/dev/null 2>&1 || { err "当前用户无法访问 Docker daemon"; return 1; }
                    docker image inspect "$SINGBOX_IMAGE" >/dev/null 2>&1 || { err "本地缺少 sing-box 镜像，安全更新路径不会拉取镜像；请先明确执行镜像更新"; return 1; }
                fi
                create_manager
                "$SB_PATH" --manage-protocols
                return $?
                ;;
            2) ;;
            *) err "无效选择，未修改节点"; return 1 ;;
        esac
    fi

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
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
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
        PSK_HY2=$(rand_pass)
        info "HY2 端口: $PORT_HY2"
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

validate_docker_ports() {
    [ "$DEPLOY_MODE" = "docker" ] || return 0
    local used_ports="|"

    validate_port() {
        local port="$1"
        local protocol="$2"
        if [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65535 )); then
            err "$protocol 端口必须是 1-65535 的整数: $port"
            return 1
        fi
    }

    claim_port() {
        local key="$1/$2"
        case "$used_ports" in
            *"|$key|"*)
                err "端口映射冲突: $key"
                return 1
                ;;
        esac
        used_ports+="$key|"
    }

    if $ENABLE_SS; then
        validate_port "$PORT_SS" "SS" || return 1
        claim_port "$PORT_SS" tcp || return 1
        claim_port "$PORT_SS" udp || return 1
    fi
    if $ENABLE_HY2; then
        validate_port "$PORT_HY2" "HY2" || return 1
        claim_port "$PORT_HY2" udp || return 1
    fi
    if $ENABLE_TUIC; then
        validate_port "$PORT_TUIC" "TUIC" || return 1
        claim_port "$PORT_TUIC" udp || return 1
    fi
    if $ENABLE_REALITY; then
        validate_port "$PORT_REALITY" "VLESS Reality" || return 1
        claim_port "$PORT_REALITY" tcp || return 1
    fi
    if $ENABLE_ANYTLS; then
        validate_port "$PORT_ANYTLS" "AnyTLS Reality" || return 1
        claim_port "$PORT_ANYTLS" tcp || return 1
    fi
}

if ! validate_docker_ports; then
    exit 1
fi

# -----------------------
# 调用 sing-box 命令
run_singbox() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        docker run --rm \
            --volume "$CONFIG_DIR:/etc/sing-box:ro" \
            --entrypoint sing-box "$SINGBOX_IMAGE" "$@"
    else
        sing-box "$@"
    fi
}

# 安装 sing-box
install_singbox() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        info "Docker 模式使用镜像中的 sing-box: $SINGBOX_IMAGE"
        return 0
    fi

    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装?(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    case "$OS" in
        alpine)
            info "使用 Edge 仓库安装 sing-box"
            apk update || { err "apk update 失败"; exit 1; }
            apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        debian|redhat)
            bash <(curl -fsSL https://sing-box.app/install.sh) || {
                err "sing-box 安装失败"
                exit 1
            }
            ;;
        *)
            err "未支持的系统,无法安装 sing-box"
            exit 1
            ;;
    esac

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对（必须在 sing-box 安装之后）
generate_reality_keys() {
    if ! $ENABLE_REALITY && ! $ENABLE_ANYTLS; then
        info "跳过 Reality 密钥生成（未选择 Reality 协议）"
        return 0
    fi

    info "生成 Reality 密钥对..."

    if [ "$DEPLOY_MODE" = "host" ] && ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 未安装，无法生成 Reality 密钥"
        exit 1
    fi

    REALITY_KEYS=$(run_singbox generate reality-keypair 2>&1) || {
        err "生成 Reality 密钥失败"
        exit 1
    }

    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(run_singbox generate rand 8 --hex 2>&1) || {
        err "生成 Reality ShortID 失败"
        exit 1
    }

    if [ -z "$REALITY_PK" ] || [ -z "$REALITY_PUB" ] || [ -z "$REALITY_SID" ]; then
        err "Reality 密钥生成结果为空"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    echo -n "$REALITY_PUB" > "$CONFIG_DIR/.reality_pub"
    echo -n "$REALITY_SID" > "$CONFIG_DIR/.reality_sid"

    info "Reality 密钥已生成"
}

generate_reality_keys

# -----------------------
# 生成 HY2/TUIC 自签证书(仅在需要时)
generate_cert() {
    if ! $ENABLE_HY2 && ! $ENABLE_TUIC; then
        info "跳过证书生成(未选择 HY2 或 TUIC)"
        return 0
    fi

    info "生成 HY2/TUIC 自签证书..."
    mkdir -p "$CONFIG_DIR/certs"

    if [ ! -f "$CONFIG_DIR/certs/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/certs/privkey.pem" ]; then
        openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout "$CONFIG_DIR/certs/privkey.pem" \
          -out "$CONFIG_DIR/certs/fullchain.pem" \
          -days 3650 \
          -subj "/CN=www.bing.com" || {
            err "证书生成失败"
            exit 1
        }
        info "证书已生成"
    else
        info "证书已存在"
    fi
}

generate_cert

# -----------------------
# 生成配置文件
create_config() {
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
    rm -f "$TEMP_INBOUNDS"

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
CACHEEOF

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
create_docker_compose_helper() {
    cat > "$CONFIG_DIR/docker-compose-refresh.sh" <<'COMPOSE_REFRESH'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="$CONFIG_DIR/config.json"
COMPOSE_PATH="$CONFIG_DIR/docker-compose.yml"
PORTS_PATH="$CONFIG_DIR/.compose-ports.$$"
COMPOSE_TMP="$COMPOSE_PATH.tmp.$$"
trap 'rm -f "$PORTS_PATH" "$COMPOSE_TMP"' EXIT
: > "$PORTS_PATH"
declare -A published_ports=()

add_port() {
    local port="$1"
    local transport="$2"
    local key="$port/$transport"

    if [[ -n "${published_ports[$key]:-}" ]]; then
        printf '[ERR] 宿主端口映射冲突: %s/%s\n' "$port" "$transport" >&2
        return 1
    fi
    published_ports[$key]=1
    printf '      - "%s:%s/%s"\n' "$port" "$port" "$transport" >> "$PORTS_PATH"
}

while IFS=$'\t' read -r inbound_type port; do
    [ -n "$inbound_type" ] || continue
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        printf '[ERR] 无效监听端口: %s\n' "$port" >&2
        exit 1
    fi

    case "$inbound_type" in
        shadowsocks)
            add_port "$port" tcp
            add_port "$port" udp
            ;;
        hysteria2|tuic)
            add_port "$port" udp
            ;;
        vless|anytls)
            add_port "$port" tcp
            ;;
        *)
            printf '[ERR] Docker 模式暂不支持发布此 inbound 类型的端口: %s\n' "$inbound_type" >&2
            exit 1
            ;;
    esac
done < <(jq -r '.inbounds[] | [.type, (.listen_port | tostring)] | @tsv' "$CONFIG_PATH")

if [ ! -s "$PORTS_PATH" ]; then
    printf '[ERR] 配置中没有可发布的端口\n' >&2
    exit 1
fi

cat > "$COMPOSE_TMP" <<'COMPOSE_HEAD'
version: "3.8"
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box:latest
    restart: unless-stopped
    command: ["run", "-c", "/etc/sing-box/config.json"]
    volumes:
      - ./:/etc/sing-box:ro
    ports:
COMPOSE_HEAD
cat "$PORTS_PATH" >> "$COMPOSE_TMP"
mv "$COMPOSE_TMP" "$COMPOSE_PATH"
COMPOSE_REFRESH
    chmod 700 "$CONFIG_DIR/docker-compose-refresh.sh"
}

# -----------------------
# 设置服务
setup_service() {
    if [ "$DEPLOY_MODE" = "docker" ]; then
        info "配置 Docker Compose 服务..."
        create_docker_compose_helper
        "$CONFIG_DIR/docker-compose-refresh.sh"
        SERVICE_PATH="$CONFIG_DIR/docker-compose.yml"
        docker_compose up -d || {
            err "Docker 容器启动失败"
            docker_compose logs --tail 30 || true
            exit 1
        }
        sleep 2
        local container_id
        container_id="$(docker_compose ps -q sing-box)"
        if [ -n "$container_id" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || true)" = "true" ]; then
            info "✅ Docker 容器已启动"
        else
            err "Docker 容器状态异常"
            docker_compose logs --tail 30 || true
            exit 1
        fi
        info "服务配置完成: $SERVICE_PATH"
        return 0
    fi

    info "配置系统服务..."

    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        local output_log_path="/dev/null"
        local error_log_path="/dev/null"
        if [ "$LOG_ENABLED" = "true" ]; then
            output_log_path="/var/log/sing-box.log"
            error_log_path="/var/log/sing-box.err"
        fi

        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="__OPENRC_OUTPUT_LOG__"
error_log="__OPENRC_ERROR_LOG__"
# 自动拉起（程序崩溃、OOM、被 kill 后自动恢复）
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        sed -i "s|__OPENRC_OUTPUT_LOG__|$output_log_path|;s|__OPENRC_ERROR_LOG__|$error_log_path|" "$SERVICE_PATH"

        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            if [ "$LOG_ENABLED" = "true" ]; then
                tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            else
                warn "当前日志已关闭，请重新运行安装器并开启日志后排查服务错误"
            fi
            exit 1
        }

        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi

    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        local systemd_stdout="null"
        local systemd_stderr="null"
        if [ "$LOG_ENABLED" = "true" ]; then
            systemd_stdout="journal"
            systemd_stderr="journal"
        fi

        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
StandardOutput=__SYSTEMD_STDOUT__
StandardError=__SYSTEMD_STDERR__
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        sed -i "s|__SYSTEMD_STDOUT__|$systemd_stdout|;s|__SYSTEMD_STDERR__|$systemd_stderr|" "$SERVICE_PATH"

        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            if [ "$LOG_ENABLED" = "true" ]; then
                journalctl -u sing-box -n 30 --no-pager
            else
                warn "当前日志已关闭，请重新运行安装器并开启日志后排查服务错误"
            fi
            exit 1
        }

        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi

    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
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
        hy2_encoded=$(printf "%s" "$PSK_HY2" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
        echo "=== Hysteria2 (HY2) ==="
        echo "hy2://${hy2_encoded}@${host}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${suffix}"
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
$ENABLE_HY2 && echo "   HY2 端口: $PORT_HY2 | 密码: $PSK_HY2"
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
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
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
}

create_manager() {
# -----------------------
# 创建 sb 管理脚本
MANAGER_PATH="$CONFIG_DIR/sb-manager.sh"
info "正在创建 sb 管理面板: $SB_PATH"

cat > "$MANAGER_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

DEPLOY_MODE="${SINGBOX_DEPLOY_MODE:-host}"
CONFIG_DIR="${SINGBOX_CONFIG_DIR:-/etc/sing-box}"
CONFIG_PATH="$CONFIG_DIR/config.json"
CACHE_FILE="$CONFIG_DIR/.config_cache"
SERVICE_NAME="sing-box"
SB_ENTRY_PATH="${SINGBOX_ENTRY_PATH:-/usr/local/bin/sb}"
umask 077

# 检测系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

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
read_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    # 缓存仅提供非事实设置；协议状态始终由 config.json 推导。
    CUSTOM_IP=""
    LOG_ENABLED="false"
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
        echo "=== Hysteria2 (HY2) ===" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "hy2://${hy2_encoded}@${PUBLIC_IP}:${HY2_PORT}/?sni=www.bing.com&alpn=h3&insecure=1#hy2${node_suffix}" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
        echo "" >> "$uri_tmp" || { rm -f "$uri_tmp"; return 1; }
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

# 重置HY2端口
action_reset_hy2() {
    read_config || return 1

    if [ "${ENABLE_HY2:-false}" != "true" ]; then
        err "HY2 协议未启用"
        return 1
    fi

    read -p "输入新的 HY2 端口(回车保持 $HY2_PORT): " new_port
    new_port="${new_port:-$HY2_PORT}"
    validate_port "$new_port" || return 1

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_port" '
    .inbounds |= map(if .type=="hysteria2" then .listen_port = $port else . end)
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已启动服务并更新 HY2 端口: $new_port"
    service_start || warn "启动服务失败"
    sleep 1
    generate_uris || warn "生成 URI 失败"
}

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
action_generate_relay() {
    read_config || return 1

    local relay_log_disabled=true
    local relay_output_log="/dev/null"
    local relay_error_log="/dev/null"
    local relay_systemd_stdout="null"
    local relay_systemd_stderr="null"
    if [ "$LOG_ENABLED" = "true" ]; then
        relay_log_disabled=false
        relay_output_log="/var/log/sing-box.log"
        relay_error_log="/var/log/sing-box.err"
        relay_systemd_stdout="journal"
        relay_systemd_stderr="journal"
    fi

    if [ "${ENABLE_SS:-false}" != "true" ]; then
        err "未检测到 SS 协议，请先通过管理面板的‘调整协议’启用 SS"
        return 1
    fi
    read_config || return 1

    # 线路机模板使用 CUSTOM_IP（若设置）或当前公共 IP
    if [ -n "${CUSTOM_IP:-}" ]; then
        INBOUND_IP="${CUSTOM_IP}"
    else
        INBOUND_IP="$(get_public_ip)"
    fi

    PUBLIC_IP="$INBOUND_IP"
    RELAY_SCRIPT="/tmp/relay-install.sh"

    info "正在生成线路机脚本: $RELAY_SCRIPT"

    cat > "$RELAY_SCRIPT" <<'RELAY_EOF'
#!/usr/bin/env bash
set -euo pipefail

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

[ "$(id -u)" != "0" ] && err "必须以 root 运行" && exit 1

detect_os(){
    . /etc/os-release 2>/dev/null || true
    case "${ID:-}" in
        alpine) OS=alpine ;;
        debian|ubuntu) OS=debian ;;
        centos|rhel|fedora) OS=redhat ;;
        *) OS=unknown ;;
    esac
}
detect_os

info "安装依赖..."
case "$OS" in
    alpine) apk update; apk add --no-cache curl jq bash openssl ca-certificates ;;
    debian) apt-get update -y; apt-get install -y curl jq bash openssl ca-certificates ;;
    redhat) yum install -y curl jq bash openssl ca-certificates ;;
esac

info "安装 sing-box..."
case "$OS" in
    alpine) apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community sing-box ;;
    *) bash <(curl -fsSL https://sing-box.app/install.sh) ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")

info "生成 Reality 密钥对"
REALITY_KEYS=$(sing-box generate reality-keypair 2>/dev/null || echo "")
REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r' || echo "")
REALITY_SID=$(sing-box generate rand 8 --hex 2>/dev/null || echo "0123456789abcdef")

read -p "请输入线路机监听端口(留空随机 20000-65000): " USER_PORT
LISTEN_PORT="${USER_PORT:-$(shuf -i 20000-65000 -n 1 2>/dev/null || echo 20443)}"

mkdir -p /etc/sing-box

cat > /etc/sing-box/config.json <<EOF
{
  "log": { "disabled": __RELAY_LOG_DISABLED__, "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": $LISTEN_PORT,
      "users": [{ "uuid": "$UUID", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "__REALITY_SNI__",
        "reality": {
          "enabled": true,
          "handshake": { "server": "__REALITY_SNI__", "server_port": 443 },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      },
      "tag": "vless-in"
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "server": "__INBOUND_IP__",
      "server_port": __INBOUND_PORT__,
      "method": "__INBOUND_METHOD__",
      "password": "__INBOUND_PASSWORD__",
      "tag": "relay-out"
    },
    { "type": "direct", "tag": "direct-out" }
  ],
  "route": { "rules": [{ "inbound": "vless-in", "outbound": "relay-out" }] }
}
EOF

if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'SVC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="__RELAY_OPENRC_OUTPUT_LOG__"
error_log="__RELAY_OPENRC_ERROR_LOG__"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 0 --respawn-delay 5"

depend() { need net; }
SVC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default
    rc-service sing-box restart
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Relay
After=network.target
[Service]
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
StandardOutput=__RELAY_SYSTEMD_STDOUT__
StandardError=__RELAY_SYSTEMD_STDERR__
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
fi

PUB_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "YOUR_RELAY_IP")

# 生成并保存链接
RELAY_URI="vless://$UUID@$PUB_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=__REALITY_SNI__&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#relay"

mkdir -p /etc/sing-box
echo "$RELAY_URI" > /etc/sing-box/relay_uri.txt

echo ""
info "✅ 安装完成"
echo "=============== 中转节点 Reality 链接 ==============="
echo "$RELAY_URI"
echo "===================================================="
echo ""
info "💡 链接已保存到: /etc/sing-box/relay_uri.txt"
info "💡 查看链接命令: cat /etc/sing-box/relay_uri.txt"
RELAY_EOF

    # 替换占位符（INBOUND_IP/PORT/METHOD/PASSWORD 同时替换 REALITY_SNI）
    sed -i "s|__INBOUND_IP__|$INBOUND_IP|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PORT__|$SS_PORT|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_METHOD__|$SS_METHOD|g" "$RELAY_SCRIPT"
    sed -i "s|__INBOUND_PASSWORD__|$SS_PSK|g" "$RELAY_SCRIPT"
    sed -i "s|__REALITY_SNI__|${REALITY_SNI:-addons.mozilla.org}|g" "$RELAY_SCRIPT"
    sed -i "s|__RELAY_LOG_DISABLED__|$relay_log_disabled|g" "$RELAY_SCRIPT"
    sed -i "s|__RELAY_OPENRC_OUTPUT_LOG__|$relay_output_log|g" "$RELAY_SCRIPT"
    sed -i "s|__RELAY_OPENRC_ERROR_LOG__|$relay_error_log|g" "$RELAY_SCRIPT"
    sed -i "s|__RELAY_SYSTEMD_STDOUT__|$relay_systemd_stdout|g" "$RELAY_SCRIPT"
    sed -i "s|__RELAY_SYSTEMD_STDERR__|$relay_systemd_stderr|g" "$RELAY_SCRIPT"

    chmod +x "$RELAY_SCRIPT"

    info "✅ 线路机脚本已生成: $RELAY_SCRIPT"
    if [ "$LOG_ENABLED" = "true" ]; then
        info "线路机运行日志: 已开启"
    else
        info "线路机运行日志: 已关闭；如需开启，请重新启用后生成线路机脚本"
    fi
    echo ""
    info "请复制以下内容到线路机执行:"
    echo "----------------------------------------"
    cat "$RELAY_SCRIPT"
    echo "----------------------------------------"
    echo ""
    info "在线路机执行命令示例："
    echo "   nano /tmp/relay-install.sh 保存后执行"
    echo "   chmod +x /tmp/relay-install.sh && bash /tmp/relay-install.sh"
    echo ""
    info "复制执行完成后，即可在线路机完成 sing-box 中转节点部署。"
}

# 协议调整功能
# 协议元数据由编号统一映射，端口冲突按传输层判定。
protocol_key() {
    case "$1" in
        1) echo ss ;; 2) echo hy2 ;; 3) echo tuic ;; 4) echo reality ;; 5) echo anytls ;;
        *) return 1 ;;
    esac
}
protocol_name() {
    case "$1" in
        ss) echo "Shadowsocks (SS)" ;; hy2) echo "Hysteria2" ;; tuic) echo "TUIC" ;;
        reality) echo "VLESS Reality" ;; anytls) echo "AnyTLS Reality" ;;
    esac
}
protocol_type() {
    case "$1" in ss) echo shadowsocks ;; hy2) echo hysteria2 ;; tuic) echo tuic ;; reality) echo vless ;; anytls) echo anytls ;; esac
}
protocol_selector() {
    case "$1" in
        ss) echo '.type == "shadowsocks"' ;;
        hy2) echo '.type == "hysteria2"' ;;
        tuic) echo '.type == "tuic"' ;;
        reality) echo '.type == "vless" and .tls.reality.enabled == true' ;;
        anytls) echo '.type == "anytls" and .tls.reality.enabled == true' ;;
    esac
}
protocol_flag() {
    case "$1" in ss) echo ENABLE_SS ;; hy2) echo ENABLE_HY2 ;; tuic) echo ENABLE_TUIC ;; reality) echo ENABLE_REALITY ;; anytls) echo ENABLE_ANYTLS ;; esac
}

# 从候选 JSON 重新生成协议标记和缓存，shell 值采用 Bash 可逆转义。
state_write_shell() {
    local output="$1" name="$2" value="$3" escaped
    printf -v escaped '%q' "$value"
    printf '%s=%s\n' "$name" "$escaped" >> "$output"
}
state_write_raw() {
    printf '%s=%s\n' "$2" "$3" >> "$1"
}
render_protocol_state() {
    local config="$1" protocols_out="$2" cache_out="$3" type key value flag selector name path pair public_key_file
    : > "$protocols_out" || return 1
    : > "$cache_out" || return 1
    for key in ss hy2 tuic reality anytls; do
        type=$(protocol_type "$key"); flag=$(protocol_flag "$key"); selector=$(protocol_selector "$key")
        if jq -e "[.inbounds[]? | select($selector)] | length > 0" "$config" >/dev/null; then value=true; else value=false; fi
        state_write_shell "$protocols_out" "$flag" "$value" || return 1
        state_write_shell "$cache_out" "$flag" "$value" || return 1
        [ "$value" = true ] || continue
        case "$key" in
            ss)
                value=$(jq -er '.inbounds[]|select(.type=="shadowsocks")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" SS_PORT "$value" || return 1
                for pair in 'SS_PSK:.password' 'SS_METHOD:.method'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"shadowsocks\")${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
            hy2)
                value=$(jq -er '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" HY2_PORT "$value" || return 1
                value=$(jq -er '.inbounds[]|select(.type=="hysteria2")|.users[0].password' "$config") || return 1
                state_write_shell "$cache_out" HY2_PSK "$value" || return 1 ;;
            tuic)
                value=$(jq -er '.inbounds[]|select(.type=="tuic")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" TUIC_PORT "$value" || return 1
                for pair in 'TUIC_UUID:.users[0].uuid' 'TUIC_PSK:.users[0].password'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"tuic\")${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
            reality)
                value=$(jq -er '.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true)|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" REALITY_PORT "$value" || return 1
                value=$(jq -er '.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true)|.users[0].uuid' "$config") || return 1
                state_write_shell "$cache_out" REALITY_UUID "$value" || return 1 ;;
            anytls)
                value=$(jq -er '.inbounds[]|select(.type=="anytls" and .tls.reality.enabled==true)|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" ANYTLS_PORT "$value" || return 1
                for pair in 'ANYTLS_USER:.users[0].name' 'ANYTLS_PSK:.users[0].password'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"anytls\" and .tls.reality.enabled==true)${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
        esac
    done
    state_write_shell "$cache_out" LOG_ENABLED "${LOG_ENABLED:-false}" || return 1
    state_write_shell "$cache_out" CUSTOM_IP "${CUSTOM_IP:-}" || return 1
    if jq -e '[.inbounds[]?|select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)]|length>0' "$config" >/dev/null; then
        for pair in 'REALITY_SNI:.tls.server_name // .tls.reality.handshake.server' 'REALITY_PK:.tls.reality.private_key' 'REALITY_SID:.tls.reality.short_id[0]'; do
            name=${pair%%:*}; path=${pair#*:}
            value=$(jq -er "[.inbounds[]?|select((.type==\"vless\" or .type==\"anytls\") and .tls.reality.enabled==true)][0] | ${path} // empty" "$config") || { err "读取候选 Reality 字段失败: $name"; return 1; }
            state_write_shell "$cache_out" "$name" "$value" || { err "写入候选 Reality 字段失败: $name"; return 1; }
        done
        public_key_file="$CONFIG_DIR/.reality_pub"
        [ -f "$TX_DIR/material/.reality_pub" ] && public_key_file="$TX_DIR/material/.reality_pub"
        if [ -f "$public_key_file" ]; then value=$(<"$public_key_file") || return 1; state_write_shell "$cache_out" REALITY_PUB "$value" || return 1; fi
    fi
}

protocol_port_free() {
    local target="$1" candidate="$2" key type port transport used
    if jq -e --arg port "$candidate" '
      [.inbounds[]? | select((.listen_port|tostring)==$port) |
       select(.type!="shadowsocks" and .type!="hysteria2" and .type!="tuic" and
         (((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true) | not))] | length>0
    ' "$CONFIG_PATH" >/dev/null; then
        return 1
    fi
    for key in ss hy2 tuic reality anytls; do
        [ "$key" = "$target" ] && continue
        case " ${PROTOCOL_REMOVING:-} " in *" $key "*) continue ;; esac
        type=$(protocol_type "$key")
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            [ "$port" = "$candidate" ] || continue
            case "$key:$target" in
                ss:*) return 1 ;; *:ss) return 1 ;;
                hy2:hy2|hy2:tuic|tuic:hy2|tuic:tuic) return 1 ;;
                reality:reality|reality:anytls|anytls:reality|anytls:anytls) return 1 ;;
            esac
        done < <(jq -r --arg t "$type" '.inbounds[]?|select(.type==$t)|.listen_port|tostring' "$CONFIG_PATH")
    done
    local staged staged_type staged_key staged_port
    for staged in "$TX_DIR"/*.json; do
        [ -f "$staged" ] || continue
        staged_type=$(jq -r '.type' "$staged")
        staged_port=$(jq -r '.listen_port|tostring' "$staged")
        [ "$staged_port" = "$candidate" ] || continue
        case "$staged_type" in shadowsocks) staged_key=ss ;; hysteria2) staged_key=hy2 ;; tuic) staged_key=tuic ;; vless) staged_key=reality ;; anytls) staged_key=anytls ;; *) continue ;; esac
        case "$staged_key:$target" in
            ss:*|*:ss|hy2:hy2|hy2:tuic|tuic:hy2|tuic:tuic|reality:reality|reality:anytls|anytls:reality|anytls:anytls) return 1 ;;
        esac
    done
    return 0
}

collect_protocol_inbound() {
    local key="$1" port="$2" method="" pass="" uuid="" user="" sni="${REALITY_SNI:-addons.mozilla.org}" pk="${REALITY_PK:-}" sid="${REALITY_SID:-}"
    case "$key" in
        ss) read -r -p 'SS 加密方式 [1=2022-blake3-aes-128-gcm, 2=aes-128-gcm，默认 1]: ' choice || choice=; method=2022-blake3-aes-128-gcm; [ "$choice" = 2 ] && method=aes-128-gcm; pass=$(rand_pass); jq -n --argjson port "$port" --arg method "$method" --arg pass "$pass" '{type:"shadowsocks",listen:"::",listen_port:$port,method:$method,password:$pass,tag:"ss-in"}' > "$TX_DIR/$key.json" ;;
        hy2) pass=$(rand_pass); jq -n --argjson port "$port" --arg pass "$pass" '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$pass}],tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$TX_DIR/$key.json" ;;
        tuic) pass=$(rand_pass); uuid=$(rand_uuid); jq -n --argjson port "$port" --arg pass "$pass" --arg uuid "$uuid" '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pass}],congestion_control:"bbr",tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$TX_DIR/$key.json" ;;
        reality) uuid=$(rand_uuid); jq -n --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$TX_DIR/$key.json" ;;
        anytls) user=$(openssl rand -hex 4); pass=$(rand_pass); jq -n --argjson port "$port" --arg user "$user" --arg pass "$pass" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$pass}],padding_scheme:[],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$TX_DIR/$key.json" ;;
    esac
}

validate_candidate_ports() {
    local candidate="$1"
    jq -e '
      [.inbounds[]? | select(.type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or ((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)) | {type,port:.listen_port}] as $managed |
      all($managed[]; (.port|type)=="number" and .port>=1 and .port<=65535 and .port==(.port|floor)) and
      ([.inbounds[]? | select(.listen_port|type=="number") | {type,port:.listen_port,reality:(.tls.reality.enabled==true)}] as $items |
       [$items[] | if .type=="shadowsocks" then "tcp/\(.port)","udp/\(.port)"
        elif .type=="hysteria2" or .type=="tuic" then "udp/\(.port)"
        elif (.type=="vless" or .type=="anytls") and .reality then "tcp/\(.port)"
        else "tcp/\(.port)","udp/\(.port)" end] | length == (unique|length))
    ' "$candidate" >/dev/null || { err '候选配置存在非法端口或 TCP/UDP 映射冲突（含未知 inbound）'; return 1; }
}

protocol_restore_trap() {
    local signal="$1" saved_trap="$2"
    if [ -n "$saved_trap" ]; then eval "$saved_trap"; else trap - "$signal"; fi
}

protocol_transaction_restore_signal_traps() {
    protocol_restore_trap INT "$saved_int_trap"
    protocol_restore_trap TERM "$saved_term_trap"
    protocol_restore_trap HUP "$saved_hup_trap"
}

protocol_transaction_signal_handler() {
    trap '' INT TERM HUP
    rollback_protocol_transaction
    protocol_transaction_restore_signal_traps
    [ -z "${TX_DIR:-}" ] || rm -rf "$TX_DIR"
    TX_DIR=""
    exit 130
}

apply_protocol_transaction() {
    local candidate="$1" new_protocols="$2" cache_candidate="$3" uri_backup="$4" file item config_check
    local saved_int_trap saved_term_trap saved_hup_trap
    saved_int_trap=$(trap -p INT); saved_term_trap=$(trap -p TERM); saved_hup_trap=$(trap -p HUP)
    local snapshot="$TX_DIR/backup"; mkdir -m 700 "$snapshot" || return 1
    local rollback_active=false
    for file in config.json .protocols .config_cache uris.txt .reality_pub .reality_sid certs/fullchain.pem certs/privkey.pem docker-compose.yml; do
        if [ -e "$CONFIG_DIR/$file" ]; then mkdir -p "$snapshot/$(dirname "$file")" || return 1; cp -p "$CONFIG_DIR/$file" "$snapshot/$file" || return 1; touch "$snapshot/$file.present" || return 1; fi
    done
    rollback_protocol_transaction() {
        local path restore_ok=true service_ok=false
        [ "$rollback_active" = true ] || return 0
        rollback_active=false
        rm -f "$CONFIG_DIR/config.json.tmp.$$" "$CONFIG_DIR/.protocols.tmp.$$" "$CONFIG_DIR/.config_cache.tmp.$$" "$CONFIG_DIR/uris.txt.tmp.$$" || restore_ok=false
        for path in config.json .protocols .config_cache uris.txt .reality_pub .reality_sid certs/fullchain.pem certs/privkey.pem docker-compose.yml; do
            if [ -f "$snapshot/$path.present" ]; then
                mkdir -p "$CONFIG_DIR/$(dirname "$path")" && cp -p "$snapshot/$path" "$CONFIG_DIR/$path" || restore_ok=false
            else
                rm -f "$CONFIG_DIR/$path" || restore_ok=false
            fi
        done
        if [ "$DEPLOY_MODE" = docker ]; then
            docker_compose up -d --force-recreate && service_ok=true
        else
            service_restart && service_ok=true
        fi
        if [ "$restore_ok" = true ] && [ "$service_ok" = true ]; then info '已恢复原配置、状态文件和服务'
        else err '回滚未能完整恢复文件或服务，请立即检查 sing-box 与 Docker Compose 状态'; fi
    }
    local check_candidate="$TX_DIR/check.json" check_cert check_key
    cp "$candidate" "$check_candidate" || return 1
    if [ -f "$TX_DIR/material/certs/fullchain.pem" ]; then
        if [ "$DEPLOY_MODE" = docker ]; then
            check_cert="/etc/sing-box/$(basename "$TX_DIR")/material/certs/fullchain.pem"
            check_key="/etc/sing-box/$(basename "$TX_DIR")/material/certs/privkey.pem"
        else
            check_cert="$TX_DIR/material/certs/fullchain.pem"
            check_key="$TX_DIR/material/certs/privkey.pem"
        fi
        jq --arg cert "$check_cert" --arg key "$check_key" '
          .inbounds |= map(if (.type=="hysteria2" or .type=="tuic") and .tls.enabled==true
            then .tls.certificate_path=$cert | .tls.key_path=$key else . end)
        ' "$candidate" > "$check_candidate" || return 1
    fi
    if [ "$DEPLOY_MODE" = docker ]; then config_check="/etc/sing-box/$(basename "$TX_DIR")/check.json"; else config_check="$check_candidate"; fi
    run_singbox check -c "$config_check" >/dev/null 2>&1 || { err '候选配置校验失败，未停止当前服务'; return 1; }
    rollback_active=true
    trap 'protocol_transaction_signal_handler INT' INT
    trap 'protocol_transaction_signal_handler TERM' TERM
    trap 'protocol_transaction_signal_handler HUP' HUP
    while IFS= read -r -d '' item; do
        local relative=${item#"$TX_DIR/material/"} target="$CONFIG_DIR/${item#"$TX_DIR/material/"}"
        mkdir -p "$(dirname "$target")"
        cp "$item" "$target" || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    done < <(find "$TX_DIR/material" -type f -print0)
    for item in "$candidate:$CONFIG_DIR/config.json" "$new_protocols:$CONFIG_DIR/.protocols" "$cache_candidate:$CONFIG_DIR/.config_cache"; do
        local src dst tmp
        src=${item%%:*}; dst=${item#*:}; tmp="$dst.tmp.$$"
        cp "$src" "$tmp" && mv "$tmp" "$dst" || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    done
    service_restart || { err '新配置服务重启失败，正在回滚'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    generate_uris || { err '链接重建失败，正在回滚'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    if ! jq -e '[.inbounds[]?|select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)]|length>0' "$CONFIG_DIR/config.json" >/dev/null; then
        rm -f "$CONFIG_DIR/.reality_pub" "$CONFIG_DIR/.reality_sid" || { err '清理已撤销 Reality 材料失败'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    fi
    if ! jq -e '[.inbounds[]?|select(.type=="hysteria2" or .type=="tuic")]|length>0' "$CONFIG_DIR/config.json" >/dev/null; then
        rm -f "$CONFIG_DIR/certs/fullchain.pem" "$CONFIG_DIR/certs/privkey.pem" || { err '清理已撤销证书失败'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    fi
    [ -f "$CONFIG_DIR/.protocols" ] || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    rollback_active=false
    protocol_transaction_restore_signal_traps
    return 0
}

action_manage_protocols_impl() {
    read_config || return 1
    local key type enabled current='' input token target='' invalid=false added='' removed='' unchanged='' port raw i
    echo '当前协议集合：'
    local index=1
    for key in ss hy2 tuic reality anytls; do
        flag=$(protocol_flag "$key"); enabled=${!flag}; printf '%s) %s %s\n' "$index" "$(protocol_name "$key")" "$([ "$enabled" = true ] && echo '[已启用]' || echo '[未启用]')"; [ "$enabled" = true ] && current+="$index "; index=$((index+1))
    done
    read -r -p '输入期望的最终协议编号（空格分隔）: ' input || input=
    [ -n "${input//[[:space:]]/}" ] || { err '协议集合不能为空，未做修改'; return 1; }
    declare -A requested=()
    for token in $input; do case "$token" in 1|2|3|4|5) requested[$token]=1 ;; *) invalid=true ;; esac; done
    [ "$invalid" = false ] || { err '包含无效编号，未做修改'; return 1; }
    [ "${#requested[@]}" -gt 0 ] || { err '至少保留一个协议'; return 1; }
    for i in 1 2 3 4 5; do
        key=$(protocol_key "$i"); flag=$(protocol_flag "$key"); enabled=${!flag}
        if [ "${requested[$i]:-}" = 1 ]; then [ "$enabled" = true ] && unchanged+="$key " || added+="$key "; else [ "$enabled" = true ] && removed+="$key "; fi
    done
    if [ -z "$added$removed" ]; then info '协议集合没有变化，无需调整'; return 0; fi
    TX_DIR=$(mktemp -d "$CONFIG_DIR/.protocol-update.XXXXXX") || return 1
    chmod 700 "$TX_DIR" && mkdir "$TX_DIR/material" || { rm -rf "$TX_DIR"; TX_DIR=""; return 1; }
    local reality_retained=false cert_retained=false
    PROTOCOL_REMOVING="$removed"
    for key in $unchanged; do case "$key" in reality|anytls) reality_retained=true ;; hy2|tuic) cert_retained=true ;; esac; done
    if [ "$cert_retained" = true ] && { [[ " $added " == *' hy2 '* ]] || [[ " $added " == *' tuic '* ]]; }; then
        if ! jq -e '[.inbounds[]?|select(.type=="hysteria2" or .type=="tuic") | .tls | select(.certificate_path=="/etc/sing-box/certs/fullchain.pem" and .key_path=="/etc/sing-box/certs/privkey.pem")]|length>0' "$CONFIG_PATH" >/dev/null || [ ! -f "$CONFIG_DIR/certs/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/certs/privkey.pem" ]; then
            err '现存 HY2/TUIC 未使用可复用的共享证书文件，拒绝更改现存协议参数'
            return 1
        fi
    fi
    if [[ " $added " == *' reality '* || " $added " == *' anytls '* ]]; then
        if [ "$reality_retained" = true ]; then
            [ -n "${REALITY_PK:-}" ] && [ -n "${REALITY_SID:-}" ] && [ -n "${REALITY_PUB:-}" ] || { err '已有 Reality 参数或 .reality_pub 缺失，拒绝改变现存 Reality 链接'; return 1; }
        else
            read -r -p 'Reality SNI（默认 addons.mozilla.org）: ' REALITY_SNI || REALITY_SNI=
            REALITY_SNI=${REALITY_SNI:-addons.mozilla.org}
            local key_output; key_output=$(run_singbox generate reality-keypair 2>&1) || { err 'Reality 密钥生成失败'; return 1; }
            REALITY_PK=$(printf '%s\n' "$key_output"|awk '/PrivateKey/{print $NF}'); REALITY_PUB=$(printf '%s\n' "$key_output"|awk '/PublicKey/{print $NF}'); REALITY_SID=$(run_singbox generate rand 8 --hex 2>&1) || return 1
            [ -n "$REALITY_PK" ] && [ -n "$REALITY_PUB" ] && [ -n "$REALITY_SID" ] || { err 'Reality 密钥参数不完整'; return 1; }
            printf '%s' "$REALITY_PUB" > "$TX_DIR/material/.reality_pub"; printf '%s' "$REALITY_SID" > "$TX_DIR/material/.reality_sid"
        fi
    fi
    if [[ " $added " == *' hy2 '* || " $added " == *' tuic '* ]]; then
        if [ "$cert_retained" = false ]; then
            mkdir -p "$TX_DIR/material/certs"
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TX_DIR/material/certs/privkey.pem" -out "$TX_DIR/material/certs/fullchain.pem" -days 3650 -subj '/CN=www.bing.com' >/dev/null 2>&1 || { err '共享证书生成失败'; return 1; }
        fi
    fi
    for key in $added; do
        read -r -p "$(protocol_name "$key") 端口（回车随机）: " raw || raw=
        if [ -z "$raw" ]; then
            local attempts=0; while :; do raw=$(rand_port); protocol_port_free "$key" "$raw" && break; attempts=$((attempts+1)); [ "$attempts" -lt 500 ] || { err '找不到可用随机端口'; return 1; }; done
        fi
        validate_port "$raw" || return 1
        protocol_port_free "$key" "$raw" || { err "端口 $raw 与目标协议发生传输层冲突"; return 1; }
        collect_protocol_inbound "$key" "$raw" || return 1
    done
    local candidate="$TX_DIR/candidate.json" jq_args=() filter=''
    for key in $removed; do type=$(protocol_type "$key"); jq_args+=(--arg "remove_$key" "$type"); filter+="| map(select(.type != \$remove_$key))"; done
    # 将不同协议的用户新增 inbound 逐项 append，未知及未变入站原样保留。
    jq '.inbounds' "$CONFIG_PATH" >/dev/null || return 1
    cp "$CONFIG_PATH" "$candidate"
    for key in $added; do candidate_tmp="$TX_DIR/step-$key.json"; jq --slurpfile inbound "$TX_DIR/$key.json" '.inbounds += $inbound' "$candidate" > "$candidate_tmp" || return 1; mv "$candidate_tmp" "$candidate"; done
    for key in $removed; do type=$(protocol_type "$key"); candidate_tmp="$TX_DIR/remove-$key.json"; selector=$(protocol_selector "$key"); jq " .inbounds |= map(select((($selector) | not))) " "$candidate" > "$candidate_tmp" || return 1; mv "$candidate_tmp" "$candidate"; done
    validate_candidate_ports "$candidate" || return 1
    render_protocol_state "$candidate" "$TX_DIR/protocols" "$TX_DIR/cache" || { err '候选协议状态生成失败，未修改节点配置'; return 1; }
    echo "将新增：${added:-无}"; echo "将删除：${removed:-无}"; echo "保持不变：${unchanged:-无}"
    read -r -p '确认应用以上变更？[y/N] ' confirm || confirm=
    [[ "$confirm" =~ ^[Yy]$ ]] || { info '已取消，未修改配置'; return 0; }
    apply_protocol_transaction "$candidate" "$TX_DIR/protocols" "$TX_DIR/cache" "$TX_DIR/uri-backup" || return 1
    read_config || return 1
    info '协议调整成功；新协议链接如下：'
    for key in $added; do case "$key" in ss) grep -A2 '^=== Shadowsocks' "$CONFIG_DIR/uris.txt" ;; hy2) grep -A1 '^=== Hysteria2' "$CONFIG_DIR/uris.txt" ;; tuic) grep -A1 '^=== TUIC' "$CONFIG_DIR/uris.txt" ;; reality) grep -A1 '^=== VLESS Reality' "$CONFIG_DIR/uris.txt" ;; anytls) grep -A1 '^=== AnyTLS Reality' "$CONFIG_DIR/uris.txt" ;; esac; done
    echo "最终协议：$(jq -r '[.inbounds[]?|select(.type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or ((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true))|.type]|join(", ")' "$CONFIG_PATH")"
}

action_manage_protocols() {
    local result=0 active_dir
    action_manage_protocols_impl "$@" || result=$?
    active_dir="${TX_DIR:-}"
    [ -z "$active_dir" ] || rm -rf "$active_dir"
    TX_DIR=""
    return "$result"
}

# 动态生成菜单
show_menu() {
    read_config 2>/dev/null || true

    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 每轮菜单重新计算映射，避免协议集合变化后遗留旧选项。
    declare -g -A MENU_MAP=()
    MENU_MAP[4]=manage_protocols
    echo "4) 调整协议"
    local option=5

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 重置 HY2 端口"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))

    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))

    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))

    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))

    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))

    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))

    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"

    cat <<MENU2
0) 退出
==========================
MENU2
}

# 管理器主循环
manager_main() {
while true; do
    show_menu
    read -p "请输入选项: " opt

    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi

    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        4) action_manage_protocols ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_reset_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac

    echo ""
done
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    if [ "${1:-}" = "--manage-protocols" ]; then
        action_manage_protocols
    else
        manager_main
    fi
fi
SB_SCRIPT

chmod +x "$MANAGER_PATH"
mkdir -p "$(dirname "$SB_PATH")"
{
    printf '#!/usr/bin/env bash\n'
    printf 'export SINGBOX_DEPLOY_MODE=%q\n' "$DEPLOY_MODE"
    printf 'export SINGBOX_CONFIG_DIR=%q\n' "$CONFIG_DIR"
    printf 'export SINGBOX_ENTRY_PATH=%q\n' "$SB_PATH"
    printf 'export SINGBOX_NODE_NAME_FILE=%q\n' "$NODE_NAME_FILE"
    printf 'exec %q "$@"\n' "$MANAGER_PATH"
} > "$SB_PATH"
chmod +x "$SB_PATH"

if [ "$DEPLOY_MODE" = "host" ]; then
    ln -sf /usr/local/bin/sb /usr/bin/sb
else
    info "Docker 模式不修改系统 PATH；请按提示使用本地 sb 管理面板"
fi
info "✅ 管理面板已创建: $SB_PATH"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
