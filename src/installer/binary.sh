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
