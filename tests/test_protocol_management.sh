#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CONFIG_DIR"

# 从安装器提取真实入口 guard，用 mock main 验证不同 Bash 调用形态，不运行安装流程。
cat > "$TMP_DIR/installer-entry.sh" <<'ENTRY'
set -euo pipefail
main() {
    printf 'main-called\n'
    printf '<%s>\n' "$@"
}
ENTRY
awk 'index($0, "if [[") == 1 && index($0, "BASH_SOURCE[0]") && index($0, "==") { start=NR } { lines[NR]=$0 } END { if (!start) exit 1; for (i=start; i<=NR; i++) print lines[i] }' "$ROOT_DIR/install-singbox.sh" >> "$TMP_DIR/installer-entry.sh"
[ -s "$TMP_DIR/installer-entry.sh" ] || { echo '未提取到安装器入口 guard' >&2; exit 1; }
entry_expected=$'main-called\n<alpha>\n<two words>\n<--flag>'
entry_output=$(bash -c "$(<"$TMP_DIR/installer-entry.sh")" guard-c alpha 'two words' --flag) || { echo 'bash -c 入口未调用 mock main' >&2; exit 1; }
[ "$entry_output" = "$entry_expected" ] || { echo 'bash -c 入口参数未原样传递' >&2; exit 1; }
entry_output=$(bash -s -- alpha 'two words' --flag < "$TMP_DIR/installer-entry.sh") || { echo 'bash -s 入口未调用 mock main' >&2; exit 1; }
[ "$entry_output" = "$entry_expected" ] || { echo 'bash -s 入口参数未原样传递' >&2; exit 1; }
entry_output=$(bash "$TMP_DIR/installer-entry.sh" alpha 'two words' --flag) || { echo 'bash file 入口未调用 mock main' >&2; exit 1; }
[ "$entry_output" = "$entry_expected" ] || { echo 'bash file 入口参数未原样传递' >&2; exit 1; }
entry_output=$(bash -c 'set -euo pipefail; source "$1"' guard-source "$TMP_DIR/installer-entry.sh") || { echo 'source 入口执行失败' >&2; exit 1; }
[ -z "$entry_output" ] || { echo 'source 文件时不应调用 main' >&2; exit 1; }

# 仅提取管理器的 literal heredoc，不执行安装器或触碰系统服务。
awk '/^cat > .*<<'"'"'SB_SCRIPT'"'"'$/ { copying=1; next } copying && /^SB_SCRIPT$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$TMP_DIR/manager.sh"
[ -s "$TMP_DIR/manager.sh" ] || { echo '未提取到管理器脚本' >&2; exit 1; }
export SINGBOX_CONFIG_DIR="$CONFIG_DIR" SINGBOX_DEPLOY_MODE=host
# shellcheck source=/dev/null
source "$TMP_DIR/manager.sh"

# 双 Reality 节点新增 HY2，模拟流式输出被 head 提前截断时的管道失败。
DUAL_REALITY_DIR="$TMP_DIR/dual-reality"
mkdir -p "$DUAL_REALITY_DIR"
jq -n '{
  inbounds: [
    {type:"vless", tag:"vless-in", listen_port:2097, users:[{uuid:"dual-uuid", flow:"xtls-rprx-vision"}]},
    {type:"anytls", tag:"anytls-in", listen_port:2087, users:[{name:"dual-user", password:"dual-password"}]}
  ] | map(.tls = {enabled:true, server_name:"dual.example.test", reality:{enabled:true, private_key:"dual-private", short_id:["aabbccdd"], handshake:{server:"dual.example.test", server_port:443}}}),
  outbounds: [{type:"direct"}]
}' > "$DUAL_REALITY_DIR/config.json"
printf 'CUSTOM_IP=203.0.113.22\nLOG_ENABLED=false\n' > "$DUAL_REALITY_DIR/.config_cache"
printf 'dual-public' > "$DUAL_REALITY_DIR/.reality_pub"
cat > "$TMP_DIR/dual-reality-child.sh" <<'DUAL_CHILD'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
run_singbox() { return 0; }
service_restart() { printf 'restart\n' >> "$CONFIG_DIR/service-calls"; }
get_public_ip() { printf '203.0.113.22'; }
rand_pass() { printf 'dual-new-hy2-password'; }
generate_uris
before_inbounds=$(jq -c '[.inbounds[] | select(.type=="vless" or .type=="anytls")]' "$CONFIG_PATH")
grep -E '^(vless|anytls)://' "$CONFIG_DIR/uris.txt" > "$CONFIG_DIR/old-links"
MOCK_REALITY_FIELD_FAIL=false
jq() {
    local output
    if [ "$MOCK_REALITY_FIELD_FAIL" = true ] && [ "${1:-}" = -er ] && [[ "${2:-}" == *'.tls.reality.private_key'* ]]; then
        return 141
    fi
    output=$(command jq "$@") || return $?
    if [ "$output" = $'dual.example.test\ndual.example.test' ]; then
        printf '%s\n' 'dual.example.test'
        sleep 0.1
        printf '%s\n' 'dual.example.test'
    else
        printf '%s\n' "$output"
    fi
}
action_manage_protocols <<< $'2 4 5\n2055\ny'
[ "$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$CONFIG_PATH")" = 2055 ]
[ "$(jq -c '[.inbounds[] | select(.type=="vless" or .type=="anytls")]' "$CONFIG_PATH")" = "$before_inbounds" ]
grep -E '^(vless|anytls)://' "$CONFIG_DIR/uris.txt" > "$CONFIG_DIR/new-links"
cmp -s "$CONFIG_DIR/old-links" "$CONFIG_DIR/new-links"
grep -q '^hy2://.*:2055/' "$CONFIG_DIR/uris.txt"
grep -q '^REALITY_SNI=dual.example.test$' "$CACHE_FILE"
[ "$(<"$CONFIG_DIR/.reality_pub")" = dual-public ]
[ "$(grep -c '^restart$' "$CONFIG_DIR/service-calls")" = 1 ]
[ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.protocol-update.*' -print -quit)" ]

# 缓存渲染与配置读取采用一致的 handshake SNI 回退。
TX_DIR="$CONFIG_DIR/render-probe"
mkdir -p "$TX_DIR/material"
jq '.inbounds |= map(if .type=="vless" or .type=="anytls" then del(.tls.server_name) else . end)' "$CONFIG_PATH" > "$TX_DIR/candidate.json"
render_protocol_state "$TX_DIR/candidate.json" "$TX_DIR/protocols" "$TX_DIR/cache"
grep -q '^REALITY_SNI=dual.example.test$' "$TX_DIR/cache"
rm -rf "$TX_DIR"
TX_DIR=""

# 真正的字段读取失败必须报明字段名，且不得改文件或重启服务。
cp "$CONFIG_PATH" "$CONFIG_DIR/config-before-failure"
cp "$CACHE_FILE" "$CONFIG_DIR/cache-before-failure"
cp "$CONFIG_DIR/uris.txt" "$CONFIG_DIR/uris-before-failure"
MOCK_REALITY_FIELD_FAIL=true
if action_manage_protocols <<< $'4 5\ny' > "$CONFIG_DIR/field-failure.log" 2>&1; then
    echo 'Reality 字段读取失败必须拒绝候选' >&2
    exit 1
fi
grep -q '读取候选 Reality 字段失败: REALITY_PK' "$CONFIG_DIR/field-failure.log"
grep -q '候选协议状态生成失败，未修改节点配置' "$CONFIG_DIR/field-failure.log"
cmp -s "$CONFIG_DIR/config-before-failure" "$CONFIG_PATH"
cmp -s "$CONFIG_DIR/cache-before-failure" "$CACHE_FILE"
cmp -s "$CONFIG_DIR/uris-before-failure" "$CONFIG_DIR/uris.txt"
[ "$(grep -c '^restart$' "$CONFIG_DIR/service-calls")" = 1 ]
[ -z "$(find "$CONFIG_DIR" -maxdepth 1 -name '.protocol-update.*' -print -quit)" ]
DUAL_CHILD
SINGBOX_CONFIG_DIR="$DUAL_REALITY_DIR" SINGBOX_DEPLOY_MODE=host bash "$TMP_DIR/dual-reality-child.sh" "$TMP_DIR/manager.sh" || { echo '双 Reality 新增 HY2 流式输出回归失败' >&2; exit 1; }

# 直接运行从安装器提取的 Docker 映射生成器，只写入 fixture 目录。
awk '/<<'"'"'COMPOSE_REFRESH'"'"'$/ { copying=1; next } copying && /^COMPOSE_REFRESH$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$TMP_DIR/docker-compose-refresh.sh"
[ -s "$TMP_DIR/docker-compose-refresh.sh" ] || { echo '未提取 Docker Compose 刷新脚本' >&2; exit 1; }
COMPOSE_FIXTURE="$TMP_DIR/compose-fixture"
mkdir -p "$COMPOSE_FIXTURE"
cp "$TMP_DIR/docker-compose-refresh.sh" "$COMPOSE_FIXTURE/docker-compose-refresh.sh"
chmod +x "$COMPOSE_FIXTURE/docker-compose-refresh.sh"
cat > "$COMPOSE_FIXTURE/config.json" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":20001},{"type":"hysteria2","listen_port":20002},{"type":"tuic","listen_port":20003},{"type":"vless","listen_port":20004},{"type":"anytls","listen_port":20005}]}
JSON
"$COMPOSE_FIXTURE/docker-compose-refresh.sh"
for mapping in '20001:20001/tcp' '20001:20001/udp' '20002:20002/udp' '20003:20003/udp' '20004:20004/tcp' '20005:20005/tcp'; do
    grep -Fq -- "- \"$mapping\"" "$COMPOSE_FIXTURE/docker-compose.yml" || { echo "Docker 映射缺失: $mapping" >&2; exit 1; }
done
jq '.inbounds[0].listen_port=20002' "$COMPOSE_FIXTURE/config.json" > "$COMPOSE_FIXTURE/conflict.json"
mv "$COMPOSE_FIXTURE/conflict.json" "$COMPOSE_FIXTURE/config.json"
if "$COMPOSE_FIXTURE/docker-compose-refresh.sh"; then echo 'Docker 刷新器应拒绝重复 UDP 映射' >&2; exit 1; fi

cat > "$CONFIG_DIR/config.json" <<'JSON'
{
  "log":{"disabled":true},
  "custom":{"keep":true},
  "inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":20001,"method":"aes-128-gcm","password":"stable-ss-secret"},{"type":"custom-in","listen_port":24000},{"type":"vless","tag":"manual-vless","listen_port":24443,"users":[{"uuid":"manual-user"}],"tls":{"enabled":true}}],
  "outbounds":[{"type":"direct","tag":"keep-out"}]
}
JSON
printf 'CUSTOM_IP=203.0.113.8\nLOG_ENABLED=false\n' > "$CONFIG_DIR/.config_cache"
printf 'ENABLE_SS=true\nENABLE_HY2=false\nENABLE_TUIC=false\nENABLE_REALITY=false\nENABLE_ANYTLS=false\n' > "$CONFIG_DIR/.protocols"
: > "$CONFIG_DIR/.reality_pub"
printf 'SS URI legacy\n' > "$CONFIG_DIR/uris.txt"

run_singbox() {
    if [ "${1:-}" = generate ] && [ "${2:-}" = reality-keypair ]; then
        printf 'PrivateKey fixture-private-new\nPublicKey fixture-public-new\n'
        return 0
    fi
    if [ "${1:-}" = generate ] && [ "${2:-}" = rand ]; then
        printf '1122334455667788'
        return 0
    fi
    if [ "${1:-}" = check ]; then
        if [ "$DEPLOY_MODE" = docker ]; then
            [[ "${3:-}" =~ ^/etc/sing-box/\.protocol-update\.[^/]+/check\.json$ ]] || { echo 'Docker 候选校验路径映射错误' >&2; return 1; }
            [ -f "$CONFIG_DIR/${3#/etc/sing-box/}" ] || { echo 'Docker 候选配置不可见' >&2; return 1; }
        else
            [ -f "${3:-}" ] || { echo 'Host 候选配置不存在' >&2; return 1; }
        fi
        [ "${MOCK_CHECK_FAIL:-false}" = false ]
        return $?
    fi
    [ "${MOCK_CHECK_FAIL:-false}" = false ]
}
service_restart() {
    SERVICE_CALLS=$(( ${SERVICE_CALLS:-0} + 1 ))
    if [ "${MOCK_COMPOSE_MUTATE:-false}" = true ] && [ "$DEPLOY_MODE" = docker ]; then printf 'generated replacement\n' > "$CONFIG_DIR/docker-compose.yml"; fi
    [ "${MOCK_RESTART_FAIL_ALL:-false}" = false ] || return 1
    [ "${MOCK_RESTART_FAIL:-false}" = false ] || return 1
    [ "${MOCK_RESTART_FAIL_AT:-0}" -ne "$SERVICE_CALLS" ]
}
MV_FAIL_ONCE=false
mv() {
    local destination="${@: -1}"
    if [ "$MV_FAIL_ONCE" = true ] && [ "$destination" = "$CONFIG_DIR/.config_cache" ]; then MV_FAIL_ONCE=false; return 1; fi
    command mv "$@"
}
get_public_ip() { printf '198.51.100.9'; }
RANDOM_PORT_MODE=false
rand_port() {
    if [ "$RANDOM_PORT_MODE" = true ]; then
        local calls=0
        [ ! -f "$TMP_DIR/random-port-calls" ] || calls=$(<"$TMP_DIR/random-port-calls")
        calls=$((calls + 1))
        printf '%s' "$calls" > "$TMP_DIR/random-port-calls"
        case "$calls" in 1) printf '24000' ;; 2) printf '20001' ;; *) printf '31002' ;; esac
    else
        printf '31002'
    fi
}
rand_pass() { local sequence=0; [ ! -f "$TMP_DIR/pass-sequence" ] || sequence=$(<"$TMP_DIR/pass-sequence"); sequence=$((sequence + 1)); printf '%s' "$sequence" > "$TMP_DIR/pass-sequence"; printf 'new-hy2-password-%s' "$sequence"; }
rand_uuid() { printf '00000000-0000-4000-8000-000000000003'; }

read_config
[ "$ENABLE_SS" = true ] && [ "$ENABLE_HY2" = false ] && [ "$ENABLE_REALITY" = false ] || { echo '协议应以实际受支持 inbound 为准' >&2; exit 1; }
old_ss_uri=$(jq -r '.inbounds[]|select(.type=="shadowsocks")|[.listen_port,.password,.method]|@tsv' "$CONFIG_DIR/config.json")
generate_uris
old_ss_link=$(grep '^ss://' "$CONFIG_DIR/uris.txt")
unknown_before=$(jq -c '{custom,outbounds,inbounds:[.inbounds[]|select(.type=="custom-in" or .tag=="manual-vless")]}' "$CONFIG_DIR/config.json")

# 一次新增 HY2，随机端口跳过未知 inbound 与 SS 占用端口，并保持旧配置不变。
RANDOM_PORT_MODE=true
action_manage_protocols <<< $'1 2\n\ny\n'
RANDOM_PORT_MODE=false
[ "$(<"$TMP_DIR/random-port-calls")" = 3 ] || { echo '随机端口选择未跳过已占用映射' >&2; exit 1; }
new_ss_uri=$(jq -r '.inbounds[]|select(.type=="shadowsocks")|[.listen_port,.password,.method]|@tsv' "$CONFIG_DIR/config.json")
[ "$old_ss_uri" = "$new_ss_uri" ] || { echo '未变 SS inbound 被修改' >&2; exit 1; }
[ "$(grep '^ss://' "$CONFIG_DIR/uris.txt")" = "$old_ss_link" ] || { echo '新增协议后未变 SS 链接未逐字保持' >&2; exit 1; }
[ "$(jq -c '{custom,outbounds,inbounds:[.inbounds[]|select(.type=="custom-in" or .tag=="manual-vless")]}' "$CONFIG_DIR/config.json")" = "$unknown_before" ] || { echo '未知/非 Reality inbound 被改动' >&2; exit 1; }
first_hy2_password="$(jq -r '.inbounds[]|select(.type=="hysteria2")|.users[0].password' "$CONFIG_DIR/config.json")"
[ "$first_hy2_password" = new-hy2-password-1 ]
[ "$(jq -r '[.inbounds[]|select(.type=="custom-in")]|length' "$CONFIG_DIR/config.json")" = 1 ]
[ "$(jq -r '.custom.keep' "$CONFIG_DIR/config.json")" = true ]
[ "$(grep -c '^ENABLE_HY2=true$' "$CONFIG_DIR/.protocols")" = 1 ]
[ -f "$CONFIG_DIR/uris.txt" ]

# 删除 HY2 后派生状态同步，未变 SS 链接仍保持一致。
ss_uri_before=$(grep '^ss://' "$CONFIG_DIR/uris.txt" | head -1)
action_manage_protocols <<< $'1\ny\n'
[ "$(jq '[.inbounds[]|select(.type=="hysteria2")]|length' "$CONFIG_DIR/config.json")" = 0 ]
[ "$(grep '^ENABLE_HY2=' "$CONFIG_DIR/.protocols")" = 'ENABLE_HY2=false' ]
[ "$(grep '^ss://' "$CONFIG_DIR/uris.txt" | head -1)" = "$ss_uri_before" ]

# 删除后重新添加必须生成新凭据。
action_manage_protocols <<< $'1 2\n31002\ny\n'
second_hy2_password="$(jq -r '.inbounds[]|select(.type=="hysteria2")|.users[0].password' "$CONFIG_DIR/config.json")"
[ "$second_hy2_password" != "$first_hy2_password" ] || { echo '重新添加未生成新凭据' >&2; exit 1; }
cert_hash_before=$(shasum -a 256 "$CONFIG_DIR/certs/fullchain.pem" | cut -d' ' -f1)
action_manage_protocols <<< $'1 2 3\n31003\ny\n'
[ "$(shasum -a 256 "$CONFIG_DIR/certs/fullchain.pem" | cut -d' ' -f1)" = "$cert_hash_before" ] || { echo '新增 TUIC 未复用现存 HY2 证书' >&2; exit 1; }
action_manage_protocols <<< $'1 3 4\nshared.example.test\n31004\ny\n'
[ "$(jq '[.inbounds[]|select(.type=="hysteria2")]|length' "$CONFIG_DIR/config.json")" = 0 ] && [ "$(jq '[.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true)]|length' "$CONFIG_DIR/config.json")" = 1 ] || { echo '同次增删协议未正确应用' >&2; exit 1; }
[ -f "$CONFIG_DIR/certs/fullchain.pem" ] || { echo '保留 TUIC 时错误删除共享证书' >&2; exit 1; }
[ "$(shasum -a 256 "$CONFIG_DIR/certs/fullchain.pem" | cut -d' ' -f1)" = "$cert_hash_before" ]
action_manage_protocols <<< $'1 3\ny\n'
[ -f "$CONFIG_DIR/certs/fullchain.pem" ] || { echo '保留 TUIC 时错误删除共享证书' >&2; exit 1; }
[ "$(shasum -a 256 "$CONFIG_DIR/certs/fullchain.pem" | cut -d' ' -f1)" = "$cert_hash_before" ]
action_manage_protocols <<< $'1\ny\n'
[ ! -e "$CONFIG_DIR/certs/fullchain.pem" ] && [ ! -e "$CONFIG_DIR/certs/privkey.pem" ] || { echo '删除共享资源族最后协议后未清理证书' >&2; exit 1; }

# 无效输入、无差异和用户取消不得写文件或调用服务。
config_before=$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)
protocols_before=$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)
cache_before=$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)
uris_before=$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)
service_calls_before=${SERVICE_CALLS:-0}
action_manage_protocols <<< $'1\ny'
if action_manage_protocols <<< $'1 9'; then echo '应拒绝无效协议编号' >&2; exit 1; fi
action_manage_protocols <<< $'1 2\n31002\nn'
[ "${SERVICE_CALLS:-0}" = "$service_calls_before" ] || { echo '无效/无差异/取消操作调用了服务' >&2; exit 1; }
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)" = "$protocols_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)" = "$cache_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)" = "$uris_before" ]

# 空集合、端口冲突和候选校验失败不破坏活动状态。
protocols_before=$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)
cache_before=$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)
uris_before=$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)
if action_manage_protocols <<< $'\n'; then echo '应拒绝空集合' >&2; exit 1; fi
if action_manage_protocols <<< $'1 2\n65536'; then echo '应拒绝超范围端口' >&2; exit 1; fi
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
if validate_candidate_ports <(jq '.inbounds += [{type:"hysteria2",listen_port:20001}]' "$CONFIG_DIR/config.json") 2>/dev/null; then echo '应拒绝 TCP/UDP 端口冲突' >&2; exit 1; fi
if validate_candidate_ports <(jq '.inbounds += [{type:"hysteria2",listen_port:24000}]' "$CONFIG_DIR/config.json") 2>/dev/null; then echo '应拒绝与未知 inbound 冲突的 UDP 端口' >&2; exit 1; fi
if validate_candidate_ports <(jq '.inbounds += [{type:"vless",listen_port:24443,tls:{enabled:true,reality:{enabled:true}}}]' "$CONFIG_DIR/config.json") 2>/dev/null; then echo '应拒绝与非 Reality vless 冲突的 TCP 端口' >&2; exit 1; fi
MOCK_CHECK_FAIL=true
if action_manage_protocols <<< $'1 2\n31002\ny\n'; then echo '应拒绝校验失败的候选配置' >&2; exit 1; fi
unset MOCK_CHECK_FAIL
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)" = "$protocols_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)" = "$cache_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)" = "$uris_before" ]

# 派生缓存提交写入失败时恢复已替换的配置、标记和共享材料。
MV_FAIL_ONCE=true
if action_manage_protocols <<< $'1 2\n31002\ny'; then echo '应处理缓存文件替换失败' >&2; exit 1; fi
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)" = "$protocols_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)" = "$cache_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)" = "$uris_before" ]
[ ! -e "$CONFIG_DIR/certs/fullchain.pem" ] && [ ! -e "$CONFIG_DIR/certs/privkey.pem" ] || { echo '状态写入失败后新证书未回滚' >&2; exit 1; }

# 常规失败返回后恢复调用者原有的 signal/RETURN traps。
trap ':' INT TERM HUP
trap -p INT TERM HUP RETURN > "$TMP_DIR/traps-before-failure"
MOCK_RESTART_FAIL_AT=$(( ${SERVICE_CALLS:-0} + 1 ))
if action_manage_protocols <<< $'1 2\n31002\ny\n'; then echo '应回滚失败的服务重启' >&2; exit 1; fi
unset MOCK_RESTART_FAIL_AT
trap -p INT TERM HUP RETURN > "$TMP_DIR/traps-after-failure"
cmp -s "$TMP_DIR/traps-before-failure" "$TMP_DIR/traps-after-failure" || { echo '常规事务失败后未恢复 signal/RETURN traps' >&2; exit 1; }
trap - INT TERM HUP
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)" = "$protocols_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)" = "$cache_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/uris.txt" | cut -d' ' -f1)" = "$uris_before" ]

# 回滚服务本身失败时明确报错，文件仍恢复到原快照。
SERVICE_CALLS=${SERVICE_CALLS:-0}
MOCK_RESTART_FAIL_AT=$((SERVICE_CALLS + 1))
MOCK_RESTART_FAIL_ALL=true
if action_manage_protocols <<< $'1 2\n31002\ny'; then echo '恢复服务失败必须向调用方返回失败' >&2; exit 1; fi
unset MOCK_RESTART_FAIL_AT MOCK_RESTART_FAIL_ALL
[ "$(shasum -a 256 "$CONFIG_DIR/config.json" | cut -d' ' -f1)" = "$config_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.protocols" | cut -d' ' -f1)" = "$protocols_before" ]
[ "$(shasum -a 256 "$CONFIG_DIR/.config_cache" | cut -d' ' -f1)" = "$cache_before" ]

# AnyTLS-only 节点从实际 inbound 读取自定义 Reality SNI，忽略过期协议标记。
CONFIG_DIR="$TMP_DIR/anytls"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"anytls","listen_port":24443,"users":[{"name":"fixture-user","password":"fixture-pass"}],"tls":{"enabled":true,"server_name":"custom.example.test","reality":{"enabled":true,"handshake":{"server":"custom.example.test","server_port":443},"private_key":"fixture-private","short_id":["aabbccdd"]}}}],"outbounds":[{"type":"direct"}]}
JSON
printf 'ENABLE_SS=true\nCUSTOM_IP=203.0.113.20\nLOG_ENABLED=false\n' > "$CACHE_FILE"
printf 'fixture-public' > "$CONFIG_DIR/.reality_pub"
read_config
generate_uris
 grep -q 'sni=custom.example.test' "$CONFIG_DIR/uris.txt" || { echo 'AnyTLS SNI 未从实际配置读取' >&2; exit 1; }
[ "$ENABLE_ANYTLS" = true ] && [ "$ENABLE_SS" = false ]

# VLESS/AnyTLS 共享 Reality 参数；保留成员时不旋转，删除族最后成员后再生成全新材料。
CONFIG_DIR="$TMP_DIR/reality"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":20001,"method":"aes-128-gcm","password":"stable-ss-secret"},{"type":"vless","tag":"vless-in","listen_port":24443,"users":[{"uuid":"00000000-0000-4000-8000-000000000004","flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":"shared.example.test","reality":{"enabled":true,"handshake":{"server":"shared.example.test","server_port":443},"private_key":"fixture-private-old","short_id":["aabbccdd"]}}}],"outbounds":[{"type":"direct"}]}
JSON
printf 'REALITY_PUB=fixture-public-old\nCUSTOM_IP=203.0.113.20\nLOG_ENABLED=false\n' > "$CACHE_FILE"
printf 'fixture-public-old' > "$CONFIG_DIR/.reality_pub"
printf 'aabbccdd' > "$CONFIG_DIR/.reality_sid"
read_config
action_manage_protocols <<< $'1 4 5\n24444\ny\n'
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.reality.private_key' "$CONFIG_PATH")" = fixture-private-old ]
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.server_name' "$CONFIG_PATH")" = shared.example.test ]
[ "$(cat "$CONFIG_DIR/.reality_pub")" = fixture-public-old ]
action_manage_protocols <<< $'1 5\ny\n'
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.reality.short_id[0]' "$CONFIG_PATH")" = aabbccdd ]
action_manage_protocols <<< $'1\ny\n'
[ ! -e "$CONFIG_DIR/.reality_pub" ] && [ ! -e "$CONFIG_DIR/.reality_sid" ] || { echo 'Reality 族最后成员删除后未清理旁路材料' >&2; exit 1; }
action_manage_protocols <<< $'1 5\nnew.example.test\n24445\ny\n'
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.reality.private_key' "$CONFIG_PATH")" = fixture-private-new ]
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.reality.short_id[0]' "$CONFIG_PATH")" = 1122334455667788 ]
[ "$(jq -r '.inbounds[]|select(.type=="anytls")|.tls.server_name' "$CONFIG_PATH")" = new.example.test ]

# 非 Reality VLESS 不被识别为管理协议；多用户 Reality 则拒绝修改。
CONFIG_DIR="$TMP_DIR/multi-user"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":20001,"method":"aes-128-gcm","password":"keep"},{"type":"vless","listen_port":24443,"tls":{"enabled":true,"reality":{"enabled":true,"private_key":"private","short_id":["aabbccdd"]}},"users":[{"uuid":"one"},{"uuid":"two"}]}],"outbounds":[{"type":"direct"}]}
JSON
printf 'REALITY_PUB=public\n' > "$CACHE_FILE"
if read_config; then echo '应拒绝管理多用户 Reality inbound' >&2; exit 1; fi

CONFIG_DIR="$TMP_DIR/missing-reality-pub"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":20001,"method":"aes-128-gcm","password":"keep"},{"type":"vless","listen_port":24443,"tls":{"enabled":true,"server_name":"reality.example","reality":{"enabled":true,"private_key":"private","handshake":{"server":"reality.example","server_port":443},"short_id":["aabbccdd"]}},"users":[{"uuid":"one","flow":"xtls-rprx-vision"}]}],"outbounds":[{"type":"direct"}]}
JSON
printf 'REALITY_PUB=stale-cached-key\n' > "$CACHE_FILE"
read_config
[ -z "$REALITY_PUB" ] || { echo '从过期缓存读取 Reality public key' >&2; exit 1; }
missing_pub_hash=$(shasum -a 256 "$CONFIG_PATH" | cut -d' ' -f1)
if action_manage_protocols <<< $'1 4 5'; then echo '应拒绝缺失旁路公钥的 Reality 复用' >&2; exit 1; fi
[ "$(shasum -a 256 "$CONFIG_PATH" | cut -d' ' -f1)" = "$missing_pub_hash" ]

# 缓存使用 shell 可逆转义，source 时不能执行凭据内容。
CONFIG_DIR="$TMP_DIR/shell-escape"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
INJECT_MARKER="$TMP_DIR/cache-injected"
jq -n --arg pass "\$(touch $INJECT_MARKER)" '{inbounds:[{type:"shadowsocks",listen_port:21001,method:"aes-128-gcm",password:$pass}],outbounds:[{type:"direct"}]}' > "$CONFIG_PATH"
CUSTOM_IP=''; LOG_ENABLED=false
render_protocol_state "$CONFIG_PATH" "$CONFIG_DIR/.protocols" "$CACHE_FILE"
read_config
[ "$SS_PSK" = "\$(touch $INJECT_MARKER)" ] && [ ! -e "$INJECT_MARKER" ] || { echo '缓存 shell 转义不安全' >&2; exit 1; }

# Docker 重启失败时恢复原 Compose 内容及配置，不调用真实 Docker。
CONFIG_DIR="$TMP_DIR/docker"
mkdir -p "$CONFIG_DIR"
CONFIG_PATH="$CONFIG_DIR/config.json" CACHE_FILE="$CONFIG_DIR/.config_cache"
DEPLOY_MODE=docker
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":20001,"method":"aes-128-gcm","password":"docker-ss"}],"outbounds":[{"type":"direct"}]}
JSON
printf 'ENABLE_SS=true\nCUSTOM_IP=203.0.113.12\nLOG_ENABLED=false\n' > "$CONFIG_DIR/.config_cache"
printf 'ENABLE_SS=true\nENABLE_HY2=false\nENABLE_TUIC=false\nENABLE_REALITY=false\nENABLE_ANYTLS=false\n' > "$CONFIG_DIR/.protocols"
printf 'old compose with custom extension\n' > "$CONFIG_DIR/docker-compose.yml"
cp "$CONFIG_DIR/docker-compose.yml" "$TMP_DIR/compose-original"
SERVICE_CALLS=${SERVICE_CALLS:-0}
MOCK_COMPOSE_MUTATE=true
MOCK_RESTART_FAIL_AT=$((SERVICE_CALLS + 1))
docker_compose() {
    [ "${1:-}" = up ] && grep -q 'old compose with custom extension' "$CONFIG_DIR/docker-compose.yml"
}
if action_manage_protocols <<< $'1 2\n31002\ny'; then echo 'Docker 新配置重启应失败并回滚' >&2; exit 1; fi
unset MOCK_RESTART_FAIL_AT MOCK_COMPOSE_MUTATE
cmp -s "$TMP_DIR/compose-original" "$CONFIG_DIR/docker-compose.yml" || { echo 'Docker Compose 自定义内容未恢复' >&2; exit 1; }
[ "$(jq '[.inbounds[]|select(.type=="hysteria2")]|length' "$CONFIG_PATH")" = 0 ] || { echo 'Docker 回滚未恢复原配置' >&2; exit 1; }

# 信号中断使用独立 Bash 子进程，断言回滚、目录清理及非零退出。
SIGNAL_DIR="$TMP_DIR/signal"
mkdir -p "$SIGNAL_DIR"
cat > "$SIGNAL_DIR/config.json" <<'JSON'
{"inbounds":[{"type":"shadowsocks","listen_port":21001,"method":"aes-128-gcm","password":"signal-stable"}],"outbounds":[{"type":"direct"}]}
JSON
printf 'CUSTOM_IP=203.0.113.21\nLOG_ENABLED=false\n' > "$SIGNAL_DIR/.config_cache"
printf 'ENABLE_SS=true\nENABLE_HY2=false\nENABLE_TUIC=false\nENABLE_REALITY=false\nENABLE_ANYTLS=false\n' > "$SIGNAL_DIR/.protocols"
printf 'old signal URI\n' > "$SIGNAL_DIR/uris.txt"
for state_file in config.json .config_cache .protocols uris.txt; do shasum -a 256 "$SIGNAL_DIR/$state_file" | cut -d' ' -f1 > "$SIGNAL_DIR/$state_file.hash"; done
cat > "$TMP_DIR/signal-child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
source "$MANAGER_PATH"
run_singbox() {
    if [ "${1:-}" = generate ] && [ "${2:-}" = reality-keypair ]; then printf 'PrivateKey signal-private\nPublicKey signal-public\n'; return 0; fi
    if [ "${1:-}" = generate ] && [ "${2:-}" = rand ]; then printf 'aabbccdd'; return 0; fi
    return 0
}
rand_pass() { printf 'signal-new-password'; }
get_public_ip() { printf '198.51.100.21'; }
SIGNAL_SENT=false
service_restart() {
    if [ "$SIGNAL_SENT" = false ]; then SIGNAL_SENT=true; kill -TERM "$$"; fi
    return 0
}
openssl() { printf 'signal-user'; }
action_manage_protocols <<< $'1 5\nsignal.example\n24445\ny'
CHILD
chmod +x "$TMP_DIR/signal-child.sh"
if MANAGER_PATH="$TMP_DIR/manager.sh" SINGBOX_CONFIG_DIR="$SIGNAL_DIR" SINGBOX_DEPLOY_MODE=host bash "$TMP_DIR/signal-child.sh" > "$TMP_DIR/signal-child.log" 2>&1; then
    echo '信号中断应以非零状态退出' >&2; exit 1
else
    signal_status=$?
fi
[ "$signal_status" -ne 0 ] || { echo '信号 fixture 返回了成功状态' >&2; exit 1; }
for state_file in config.json .config_cache .protocols uris.txt; do
    [ "$(shasum -a 256 "$SIGNAL_DIR/$state_file" | cut -d' ' -f1)" = "$(<"$SIGNAL_DIR/$state_file.hash")" ] || { echo "信号回滚未恢复 $state_file" >&2; exit 1; }
done
[ -z "$(find "$SIGNAL_DIR" -maxdepth 1 -name '.protocol-update.*' -print -quit)" ] || { echo '信号中断留下协议事务目录' >&2; exit 1; }

# 已有节点入口只更新管理器并进入协议调整，不调用完整安装路径。
SAFE_DIR="$TMP_DIR/safe-upgrade"
mkdir -p "$SAFE_DIR" "$TMP_DIR/fake-bin"
printf '{"inbounds":[{"type":"shadowsocks","listen_port":21001,"password":"unchanged"}],"outbounds":[{"type":"direct"}]}\n' > "$SAFE_DIR/config.json"
SAFE_CONFIG_HASH=$(shasum -a 256 "$SAFE_DIR/config.json" | cut -d' ' -f1)
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/fake-bin/docker"
chmod +x "$TMP_DIR/fake-bin/docker"
PATH="$TMP_DIR/fake-bin:$PATH"
export SAFE_ARG_MARKER="$TMP_DIR/safe-args" SAFE_MANAGER_MARKER="$TMP_DIR/safe-manager"
# shellcheck source=/dev/null
source "$ROOT_DIR/install-singbox.sh"
select_deploy_mode() {
    DEPLOY_MODE=docker CONFIG_DIR="$SAFE_DIR" CONFIG_PATH="$SAFE_DIR/config.json" CACHE_FILE="$SAFE_DIR/.config_cache" PROTOCOL_FILE="$SAFE_DIR/.protocols"
    SB_PATH="$SAFE_DIR/sb" NODE_NAME_FILE="$SAFE_DIR/node_names.txt" SINGBOX_IMAGE=test-singbox-image
}
create_manager() {
    printf 'created\n' > "$SAFE_MANAGER_MARKER"
    printf '#!/usr/bin/env bash\nprintf "%%s" "$*" > "$SAFE_ARG_MARKER"\n' > "$SB_PATH"
    chmod +x "$SB_PATH"
}
main --docker <<< '1'
[ -f "$SAFE_MANAGER_MARKER" ] && [ "$(<"$SAFE_ARG_MARKER")" = '--manage-protocols' ] || { echo '安全升级未仅更新管理器并进入协议调整' >&2; exit 1; }
[ "$(shasum -a 256 "$SAFE_DIR/config.json" | cut -d' ' -f1)" = "$SAFE_CONFIG_HASH" ] || { echo '安全升级路径修改了既有配置' >&2; exit 1; }
[ ! -e "$SAFE_DIR/.config_cache" ] && [ ! -e "$SAFE_DIR/.protocols" ] || { echo '安全升级路径写入了状态配置' >&2; exit 1; }

printf '协议管理 fixture 测试通过\n'
