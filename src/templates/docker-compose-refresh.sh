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
