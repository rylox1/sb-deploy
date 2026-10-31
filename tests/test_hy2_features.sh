#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CONFIG_DIR"
export SINGBOX_CONFIG_DIR="$CONFIG_DIR" SINGBOX_DEPLOY_MODE=host

awk '/^cat > .*<<'"'"'SB_SCRIPT'"'"'$/ { copying=1; next } copying && /^SB_SCRIPT$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$TMP_DIR/manager.sh"
[ -s "$TMP_DIR/manager.sh" ] || { echo '未提取到管理器脚本' >&2; exit 1; }
# shellcheck source=/dev/null
source "$TMP_DIR/manager.sh"

# 端口范围边界、间隔校验与 UDP 冲突规则。
validate_hy2_hopping_settings 20000 20001 15 20000
validate_hy2_hopping_settings 20000 20099 3600 20000
for invalid in '20000 20000 15' '20000 20100 15' '20100 20000 15' '0 2 15' '65535 65536 15' '20000 20001 4' '20000 20001 3601'; do
    read -r start end interval <<< "$invalid"
    if validate_hy2_hopping_settings "$start" "$end" "$interval" 20000 >/dev/null 2>&1; then
        echo "错误地接受了无效跳跃值: $invalid" >&2
        exit 1
    fi
done
cat > "$TMP_DIR/range-config.json" <<'JSON'
{"inbounds":[
 {"type":"hysteria2","listen_port":20000},
 {"type":"vless","listen_port":20001,"tls":{"reality":{"enabled":true}}}
]}
JSON
validate_hy2_port_conflicts "$TMP_DIR/range-config.json" 20000 20099
jq '.inbounds += [{"type":"custom","listen_port":20055}]' "$TMP_DIR/range-config.json" > "$TMP_DIR/conflict.json"
if validate_hy2_port_conflicts "$TMP_DIR/conflict.json" 20000 20099 >/dev/null 2>&1; then
    echo 'HY2 跳跃范围错误地接受未知 UDP inbound 冲突' >&2
    exit 1
fi

# 三类 URI 按协议约定隔离扩展参数，验证 Brutal 方向和 IPv6 authority。
cat > "$CONFIG_DIR/config.json" <<'JSON'
{"inbounds":[{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":20000,"ignore_client_bandwidth":true,"up_mbps":50,"down_mbps":80,"users":[{"password":"secret:+/=?&@#"}],"tls":{"enabled":true,"alpn":["h3"]}}],"outbounds":[{"type":"direct"}]}
JSON
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=2001:db8::1
LOG_ENABLED=false
HY2_HOPPING_ENABLED=true
HY2_HOP_START=20000
HY2_HOP_END=20002
HY2_HOP_INTERVAL=27
CACHE
get_public_ip() { printf '198.51.100.1'; }
read_config
TX_DIR="$TMP_DIR/protocol-port-check"
mkdir -p "$TX_DIR"
if protocol_port_free tuic 20001; then
    echo '随机 UDP 协议端口错误地允许占用 HY2 跳跃范围' >&2
    exit 1
fi
protocol_port_free reality 20001
rm -rf "$TX_DIR"
generate_uris
URI_FILE="$CONFIG_DIR/uris.txt"
[ -f "$URI_FILE" ]
standard=$(awk '/^=== Hysteria2 标准/{getline; print}' "$URI_FILE")
shadowrocket=$(awk '/^=== Hysteria2 Shadowrocket/{getline; print}' "$URI_FILE")
mihomo=$(awk '/^=== Hysteria2 Mihomo/{getline; print}' "$URI_FILE")
[ "$standard" = 'hy2://secret%3A%2B%2F%3D%3F%26%40%23@[2001:db8::1]:20000-20002/?sni=www.bing.com&alpn=h3&insecure=1#hy2' ]
[[ "$standard" != *'hop-interval='* && "$standard" != *'&up='* && "$standard" != *'&down='* ]]
[ "$shadowrocket" = 'hy2://secret%3A%2B%2F%3D%3F%26%40%23@[2001:db8::1]:20000/?mport=20000-20002&sni=www.bing.com&alpn=h3&insecure=1#hy2' ]
[[ "$shadowrocket" != *'hop-interval='* && "$shadowrocket" != *'&up='* && "$shadowrocket" != *'&down='* ]]
[ "$mihomo" = 'hy2://secret%3A%2B%2F%3D%3F%26%40%23@[2001:db8::1]:20000-20002/?sni=www.bing.com&alpn=h3&insecure=1&hop-interval=27&up=80&down=50#hy2' ]
grep -q 'Shadowrocket 请手动核对' "$URI_FILE"
printf '%s' '-node #1' > "$CONFIG_DIR/node_names.txt"
generate_uris
[ "$(grep -c '^hy2://.*#hy2-node%20%231$' "$URI_FILE")" -eq 3 ] || { echo 'HY2 URI fragment 未正确进行 URL 编码' >&2; exit 1; }
rm -f "$CONFIG_DIR/node_names.txt"
generate_uris

# Docker bridge 发布范围内每个 UDP host 端口到同一容器监听端口。
awk '/<<'"'"'COMPOSE_REFRESH'"'"'$/ { copying=1; next } copying && /^COMPOSE_REFRESH$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$TMP_DIR/docker-compose-refresh.sh"
COMPOSE_DIR="$TMP_DIR/compose"
mkdir -p "$COMPOSE_DIR"
cp "$TMP_DIR/docker-compose-refresh.sh" "$COMPOSE_DIR/docker-compose-refresh.sh"
chmod +x "$COMPOSE_DIR/docker-compose-refresh.sh"
cp "$CONFIG_DIR/config.json" "$COMPOSE_DIR/config.json"
cp "$CONFIG_DIR/.config_cache" "$COMPOSE_DIR/.config_cache"
"$COMPOSE_DIR/docker-compose-refresh.sh"
for port in 20000 20001 20002; do grep -Fq -- "- \"$port:20000/udp\"" "$COMPOSE_DIR/docker-compose.yml"; done
[ "$(grep -c '/udp' "$COMPOSE_DIR/docker-compose.yml")" -eq 3 ]
! grep -q 'network_mode: host' "$COMPOSE_DIR/docker-compose.yml"

# sb 配置流程事务化更新跳跃/Brutal，并正确映射服务端方向。
DEPLOY_MODE=docker
run_singbox() { return 0; }
service_restart() { printf 'restart\n' >> "$TMP_DIR/manager-service-calls"; }
action_configure_hy2 <<< $'21000\ny\n21000-21002\n27\ny\n80\n50\ny\n'
[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|[.listen_port,.ignore_client_bandwidth,.up_mbps,.down_mbps]|@tsv' "$CONFIG_DIR/config.json")" = $'21000\ttrue\t50\t80' ]
grep -q '^HY2_HOPPING_ENABLED=true$' "$CONFIG_DIR/.config_cache"
grep -q '^HY2_HOP_START=21000$' "$CONFIG_DIR/.config_cache"
grep -q '^HY2_CLIENT_UP_MBPS=80$' "$CONFIG_DIR/.config_cache"
grep -q 'hop-interval=27&up=80&down=50' "$URI_FILE"
action_configure_hy2 <<< $'\nN\nN\ny\n'
[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|[.ignore_client_bandwidth,(.up_mbps // "none"),(.down_mbps // "none")]|@tsv' "$CONFIG_DIR/config.json")" = $'true\tnone\tnone' ]
grep -q '^HY2_HOPPING_ENABLED=false$' "$CONFIG_DIR/.config_cache"
! grep -E '^hy2://.*(hop-interval=|[?&]up=|[?&]down=)' "$URI_FILE"
[ "$(grep -c '^restart$' "$TMP_DIR/manager-service-calls")" -eq 2 ]

# Host nftables helper 仅触碰项目专属 inet 表，apply/clear 可重复执行。
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=example.test
LOG_ENABLED=false
HY2_HOPPING_ENABLED=true
HY2_HOP_START=21000
HY2_HOP_END=21002
HY2_HOP_INTERVAL=27
CACHE
awk 'index($0, "cat > \"$CONFIG_DIR/hy2-port-hopping.sh\" <<\047HOPPING_SCRIPT\047") { copying=1; next } copying && /^HOPPING_SCRIPT$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$CONFIG_DIR/hy2-port-hopping.sh"
[ -s "$CONFIG_DIR/hy2-port-hopping.sh" ] || { echo '未提取到 Host nftables helper' >&2; exit 1; }
chmod +x "$CONFIG_DIR/hy2-port-hopping.sh"
MOCK_BIN="$TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/nft" <<'NFT'
#!/usr/bin/env bash
if [ "$*" = '-f -' ]; then
    while IFS= read -r line; do printf '%s\n' "$line" >> "$NFT_CALLS"; done
    [ "${NFT_BATCH_FAIL:-false}" = false ]
    exit $?
fi
printf '%s\n' "$*" >> "$NFT_CALLS"
if [ "$*" = 'list tables' ]; then printf 'table inet sb_deploy_hy2\n'; fi
if [ "$*" = 'delete table inet sb_deploy_hy2' ] && [ "${NFT_DELETE_FAIL:-false}" = true ]; then exit 1; fi
NFT
chmod +x "$MOCK_BIN/nft"
export NFT_CALLS="$TMP_DIR/nft-calls" PATH="$MOCK_BIN:$PATH"
"$CONFIG_DIR/hy2-port-hopping.sh" apply
"$CONFIG_DIR/hy2-port-hopping.sh" apply
"$CONFIG_DIR/hy2-port-hopping.sh" clear
[ "$(grep -c '^add table inet sb_deploy_hy2$' "$NFT_CALLS")" -eq 2 ]
grep -q 'udp dport 21000-21002 redirect to :21000' "$NFT_CALLS"
[ "$(grep -c '^delete table inet sb_deploy_hy2$' "$NFT_CALLS")" -ge 3 ]
! grep -q 'delete table inet [^s]' "$NFT_CALLS"
if NFT_DELETE_FAIL=true "$CONFIG_DIR/hy2-port-hopping.sh" clear; then
    echo 'nftables 删除规则失败未向调用者传播' >&2
    exit 1
fi
if NFT_BATCH_FAIL=true "$CONFIG_DIR/hy2-port-hopping.sh" apply; then
    echo 'nftables 规则批次应用失败未向调用者传播' >&2
    exit 1
fi

# 固定端口 BBR 输出不携带 hop-interval/up/down；配置保持强制 BBR。
jq '.inbounds |= map(if .type=="hysteria2" then del(.up_mbps,.down_mbps) | .ignore_client_bandwidth=true | .listen_port=21000 else . end)' "$CONFIG_DIR/config.json" > "$CONFIG_DIR/config-fixed.json"
mv "$CONFIG_DIR/config-fixed.json" "$CONFIG_DIR/config.json"
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=example.test
LOG_ENABLED=false
HY2_HOPPING_ENABLED=false
HY2_HOP_START=''
HY2_HOP_END=''
HY2_HOP_INTERVAL=15
CACHE
read_config
generate_uris
! grep -E '^hy2://.*(hop-interval=|[?&]up=|[?&]down=)' "$URI_FILE"
grep -q 'ignore_client_bandwidth' < <(jq -r '.inbounds[]|select(.type=="hysteria2")|keys[]' "$CONFIG_DIR/config.json")

# HY2 + Reality 下 TX_DIR 尚未建立时也能渲染状态，并保留旁路公钥。
jq '.inbounds += [{type:"vless",tag:"vless-in",listen:"::",listen_port:24443,users:[{uuid:"fixture-uuid",flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:"reality.example.test",reality:{enabled:true,private_key:"fixture-private",short_id:["aabbccdd"],handshake:{server:"reality.example.test",server_port:443}}}}]' "$CONFIG_DIR/config.json" > "$CONFIG_DIR/config-with-reality.json"
mv "$CONFIG_DIR/config-with-reality.json" "$CONFIG_DIR/config.json"
printf 'fixture-public-key' > "$CONFIG_DIR/.reality_pub"
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=example.test
LOG_ENABLED=false
HY2_HOPPING_ENABLED=false
HY2_HOP_INTERVAL=15
CACHE
get_public_ip() { printf '198.51.100.1'; }
read_config
unset TX_DIR
hy2_hopping_service_file() { touch "$TMP_DIR/docker-service-path-accessed"; printf '%s\n' "$TMP_DIR/host-service"; }
action_configure_hy2 <<< $'\nN\nN\ny\n'
grep -q '^REALITY_PUB=fixture-public-key$' "$CONFIG_DIR/.config_cache"
[ ! -e "$TMP_DIR/docker-service-path-accessed" ] || { echo 'Docker 事务访问了 Host hopping service 路径' >&2; exit 1; }

# Host 回滚恢复已存在 hopping unit 时必须重新启用开机持久性。
DEPLOY_MODE=host
OS=debian
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=example.test
LOG_ENABLED=false
HY2_HOPPING_ENABLED=true
HY2_HOP_START=21000
HY2_HOP_END=21001
HY2_HOP_INTERVAL=15
CACHE
printf 'original-hopping-unit\n' > "$TMP_DIR/host-service"
hy2_hopping_service_file() { printf '%s\n' "$TMP_DIR/host-service"; }
cat > "$MOCK_BIN/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
SYSTEMCTL
chmod +x "$MOCK_BIN/systemctl"
export SYSTEMCTL_CALLS="$TMP_DIR/systemctl-calls"
service_restart() {
    if [ "${FAIL_RESTART_ONCE:-false}" = true ]; then FAIL_RESTART_ONCE=false; return 1; fi
    return 0
}
FAIL_RESTART_ONCE=true
if action_configure_hy2 <<< $'\nN\nN\ny\n'; then
    echo 'Host fixture 预期触发重启失败并回滚' >&2
    exit 1
fi
[ "$(<"$TMP_DIR/host-service")" = original-hopping-unit ]
grep -q '^enable sb-deploy-hy2-hopping.service$' "$SYSTEMCTL_CALLS" || { echo 'Host rollback 未恢复 hopping unit 开机启用状态' >&2; exit 1; }
[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$CONFIG_DIR/config.json")" = 21000 ]

# 可选本地集成门，与仓库 fixture 分离且不硬编码用户目录。
MIHOMO_KIT_ROOT="${MIHOMO_KIT_ROOT:-$HOME/.config/mihomo}"
if [ -f "$MIHOMO_KIT_ROOT/tests/test_links.py" ] && command -v python3 >/dev/null 2>&1; then
    PYTHONPATH="$MIHOMO_KIT_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -m pytest -q \
        "$MIHOMO_KIT_ROOT/tests/test_links.py" \
        -k 'hysteria2_hop_interval_and_brutal_bandwidth or hysteria2_mport_overrides_authority_ports'
    export HY2_TEST_MIHOMO_URI="$mihomo" HY2_TEST_BBR_URI="$(grep '^hy2://' "$URI_FILE" | head -1)"
    PYTHONPATH="$MIHOMO_KIT_ROOT${PYTHONPATH:+:$PYTHONPATH}" python3 -c '
from mihomo_kit.links import parse_link
import os
proxy = parse_link(os.environ["HY2_TEST_MIHOMO_URI"])
assert proxy["server"] == "2001:db8::1" and proxy["port"] == 20000
assert proxy["ports"] == "20000-20002" and proxy["hop-interval"] == 27
assert proxy["up"] == "80" and proxy["down"] == "50"
assert proxy["sni"] == "www.bing.com" and proxy["alpn"] == ["h3"]
assert proxy["skip-cert-verify"] is True
bbr = parse_link(os.environ["HY2_TEST_BBR_URI"])
assert bbr["port"] == 21000 and "ports" not in bbr
assert "up" not in bbr and "down" not in bbr and "hop-interval" not in bbr
'
else
    printf 'mihomo-kit 集成测试未执行（未找到 %s/tests/test_links.py）\n' "$MIHOMO_KIT_ROOT"
fi

echo 'HY2 功能 fixture 测试通过'
