#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/nft" <<'NFT_MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'nft %s\n' "$*" >> "$NFT_LOG"
case "$*" in
    'list tables')
        [ "${NFT_ACCESS:-true}" = true ] || exit 1
        [ ! -f "$NFT_TABLE" ] || printf '%s\n' 'table inet sb_deploy_hy2'
        ;;
    '-f -')
        batch=$(< /dev/stdin)
        [ "${NFT_APPLY_FAIL:-false}" = false ] || exit 1
        if [[ "$batch" == *'delete table inet sb_deploy_hy2'* ]]; then rm -f "$NFT_TABLE"; fi
        if [[ "$batch" == *'add table inet sb_deploy_hy2'* ]]; then : > "$NFT_TABLE"; fi
        ;;
    'delete table inet sb_deploy_hy2')
        [ "${NFT_DELETE_FAIL:-false}" = false ] || exit 1
        if [ -n "${NFT_DELETE_FAIL_ONCE_FILE:-}" ] && [ -f "$NFT_DELETE_FAIL_ONCE_FILE" ]; then rm -f "$NFT_DELETE_FAIL_ONCE_FILE"; exit 1; fi
        rm -f "$NFT_TABLE"
        ;;
    *) exit 1 ;;
esac
NFT_MOCK
chmod +x "$MOCK_BIN/nft"
PATH="$MOCK_BIN:$PATH"
export PATH
SINGBOX_CONFIG_DIR="$TMP_DIR/seed" SINGBOX_DEPLOY_MODE=host
export SINGBOX_CONFIG_DIR SINGBOX_DEPLOY_MODE
awk '/^cat > .*<<'"'"'SB_SCRIPT'"'"'$/ { copying=1; next } copying && /^SB_SCRIPT$/ { exit } copying { print }' \
    "$ROOT_DIR/install-singbox.sh" > "$TMP_DIR/manager.sh"
[ -s "$TMP_DIR/manager.sh" ] || { printf '未提取到生成管理器\n' >&2; exit 1; }
# shellcheck source=/dev/null
source "$TMP_DIR/manager.sh"

info() { :; }
warn() { :; }
err() { printf '[ERR] %s\n' "$*" >&2; }
OS=debian DEPLOY_MODE=host SERVICE_NAME=sing-box
NFT_LOG="$TMP_DIR/nft.log"
export NFT_LOG
NFT_ACCESS=true NFT_APPLY_FAIL=false NFT_DELETE_FAIL=false NFT_DELETE_FAIL_ONCE_FILE=""
export NFT_ACCESS NFT_APPLY_FAIL NFT_DELETE_FAIL NFT_DELETE_FAIL_ONCE_FILE
SYSTEMCTL_LOG="$TMP_DIR/systemctl.log"
export SYSTEMCTL_LOG
SYSTEMCTL_ENABLED=false SYSTEMCTL_ACTIVE=false
SYSTEMCTL_HOP_RESTART_FAIL=false SINGBOX_RESTART_FAIL=false SYSTEMCTL_DAEMON_FAIL=false SYSTEMCTL_ENABLE_FAIL=false
export SYSTEMCTL_ENABLED SYSTEMCTL_ACTIVE SYSTEMCTL_HOP_RESTART_FAIL SINGBOX_RESTART_FAIL SYSTEMCTL_DAEMON_FAIL SYSTEMCTL_ENABLE_FAIL
FAIL_CP_DEST="" URI_FAIL=false

systemctl() {
    printf 'systemctl %s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$1" in
        is-enabled) [ "$SYSTEMCTL_ENABLED" = true ] ;;
        is-active) [ "$SYSTEMCTL_ACTIVE" = true ] ;;
        daemon-reload) [ "$SYSTEMCTL_DAEMON_FAIL" = false ] ;;
        enable)
            [ "$SYSTEMCTL_ENABLE_FAIL" = false ] || return 1
            SYSTEMCTL_ENABLED=true
            ;;
        disable) SYSTEMCTL_ENABLED=false ;;
        stop) SYSTEMCTL_ACTIVE=false ;;
        restart)
            case "$2" in
                sb-deploy-hy2-hopping.service)
                    "$CONFIG_DIR/hy2-port-hopping.sh" apply || return 1
                    if [ "$SYSTEMCTL_HOP_RESTART_FAIL" = true ]; then SYSTEMCTL_HOP_RESTART_FAIL=false; return 1; fi
                    SYSTEMCTL_ACTIVE=true
                    ;;
                sing-box)
                    if [ "$SINGBOX_RESTART_FAIL" = true ]; then SINGBOX_RESTART_FAIL=false; return 1; fi
                    ;;
            esac
            ;;
        start) : ;;
        *) : ;;
    esac
}

rc-update() {
    printf 'rc-update %s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$1" in
        add)
            [ "${RC_ADD_FAIL:-false}" = false ] || return 1
            mkdir -p "$(dirname "$RUNLEVEL_FILE")"
            ln -sf enabled "$RUNLEVEL_FILE"
            ;;
        del) rm -f "$RUNLEVEL_FILE" ;;
    esac
}
rc-service() {
    printf 'rc-service %s\n' "$*" >> "$SYSTEMCTL_LOG"
    case "$2" in
        status) [ "${RC_ACTIVE:-false}" = true ] ;;
        stop) RC_ACTIVE=false ;;
        start|restart)
            if [ "${RC_RESTART_FAIL:-false}" = true ]; then RC_RESTART_FAIL=false; return 1; fi
            "$CONFIG_DIR/hy2-port-hopping.sh" apply || return 1
            RC_ACTIVE=true
            ;;
        *) : ;;
    esac
}

cp() {
    if [ -n "$FAIL_CP_DEST" ] && [ "${@: -1}" = "$FAIL_CP_DEST" ]; then
        FAIL_CP_DEST=""
        return 1
    fi
    command cp "$@"
}
run_singbox() { [ "${1:-}" = check ]; }
generate_uris() {
    if [ "$URI_FAIL" = true ]; then URI_FAIL=false; return 1; fi
    printf 'generated-uri\n' > "$CONFIG_DIR/uris.txt"
}
get_public_ip() { printf '203.0.113.7'; }

hy2_hopping_service_file() { printf '%s\n' "$HY2_SERVICE_FILE"; }
hy2_hopping_runlevel_file() { printf '%s\n' "$RUNLEVEL_FILE"; }

init_case() {
    local name="$1" old_mode="$2"
    CASE_DIR="$TMP_DIR/$name"
    CONFIG_DIR="$CASE_DIR/config"
    CONFIG_PATH="$CONFIG_DIR/config.json"
    CACHE_FILE="$CONFIG_DIR/.config_cache"
    NFT_TABLE="$CASE_DIR/nft-table"
    NFT_DELETE_FAIL_ONCE_FILE="$CASE_DIR/nft-delete-once"
    HY2_SERVICE_FILE="$CASE_DIR/systemd/sb-deploy-hy2-hopping.service"
    RUNLEVEL_FILE="$CASE_DIR/runlevels/default/sb-deploy-hy2-hopping"
    mkdir -p "$CONFIG_DIR" "$(dirname "$HY2_SERVICE_FILE")" "$(dirname "$RUNLEVEL_FILE")"
    export NFT_TABLE
    SYSTEMCTL_ENABLED=false SYSTEMCTL_ACTIVE=false
    SYSTEMCTL_HOP_RESTART_FAIL=false SINGBOX_RESTART_FAIL=false SYSTEMCTL_DAEMON_FAIL=false SYSTEMCTL_ENABLE_FAIL=false
    NFT_ACCESS=true NFT_APPLY_FAIL=false NFT_DELETE_FAIL=false
    URI_FAIL=false FAIL_CP_DEST=""
    : > "$SYSTEMCTL_LOG"; : > "$NFT_LOG"
    cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":22000,"users":[{"password":"old-password"}],"ignore_client_bandwidth":true,"tls":{"enabled":true,"certificate_path":"/etc/sing-box/certs/fullchain.pem","key_path":"/etc/sing-box/certs/privkey.pem"}}],"outbounds":[{"type":"direct"}]}
JSON
    cat > "$CACHE_FILE" <<CACHE
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=$old_mode
LOG_ENABLED=false
CUSTOM_IP=example.test
CACHE
    printf 'old-protocol-marker\n' > "$CONFIG_DIR/.protocols"
    printf 'old-uri\n' > "$CONFIG_DIR/uris.txt"
    DEPLOY_MODE=host OS=debian
    read_config
    if [ "$old_mode" = nftables ]; then
        reconcile_hy2_hopping_runtime
        [ -f "$NFT_TABLE" ] && [ -x "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ -e "$HY2_SERVICE_FILE" ]
        [ "$SYSTEMCTL_ACTIVE" = true ] && [ "$SYSTEMCTL_ENABLED" = true ]
    fi
}

prepare_transaction() {
    local new_mode="$1" shape="${2:-hopping}"
    TX_DIR="$CONFIG_DIR/.protocol-update.fixture"
    mkdir -p "$TX_DIR/material"
    TX_CANDIDATE="$TX_DIR/candidate.json"
    TX_PROTOCOLS="$TX_DIR/protocols"
    TX_CACHE="$TX_DIR/cache"
    TX_URI_BACKUP="$TX_DIR/uri-backup"
    cp "$CONFIG_PATH" "$TX_CANDIDATE"
    jq '.inbounds[0].users[0].password="new-password"' "$TX_CANDIDATE" > "$TX_DIR/candidate.tmp"
    mv "$TX_DIR/candidate.tmp" "$TX_CANDIDATE"
    printf 'new-protocol-marker\n' > "$TX_PROTOCOLS"
    if [ "$shape" = hopping ]; then
        cat > "$TX_CACHE" <<CACHE
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=$new_mode
LOG_ENABLED=false
CUSTOM_IP=example.test
CACHE
    elif [ "$shape" = closed ]; then
        cat > "$TX_CACHE" <<'CACHE'
HY2_HOPPING_ENABLED=false
HY2_HOP_START=''
HY2_HOP_END=''
HY2_HOP_INTERVAL=15
LOG_ENABLED=false
CUSTOM_IP=example.test
CACHE
    else
        cat > "$TX_CACHE" <<'CACHE'
LOG_ENABLED=false
CUSTOM_IP=example.test
CACHE
        jq '.inbounds=[]' "$TX_CANDIDATE" > "$TX_DIR/no-hy2.json"
        mv "$TX_DIR/no-hy2.json" "$TX_CANDIDATE"
    fi
    HY2_HOPPING_ENABLED=true
    HY2_HOP_START=22000 HY2_HOP_END=22002 HY2_HOP_INTERVAL=15
    HY2_HOPPING_FORWARD_MODE="$new_mode"
    ENABLE_HY2=true
}

assert_restored_mode() {
    local mode="$1" before_config="$2" before_cache="$3" before_protocols="$4" before_uri="$5"
    cmp -s "$CONFIG_PATH" "$before_config"
    cmp -s "$CACHE_FILE" "$before_cache"
    cmp -s "$CONFIG_DIR/.protocols" "$before_protocols"
    cmp -s "$CONFIG_DIR/uris.txt" "$before_uri"
    [ "$(awk -F= '$1=="HY2_HOPPING_FORWARD_MODE" {print $2}' "$CACHE_FILE")" = "$mode" ]
    if [ "$mode" = nftables ]; then
        [ -f "$NFT_TABLE" ] && [ -x "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ -e "$HY2_SERVICE_FILE" ]
        [ "$SYSTEMCTL_ACTIVE" = true ] && [ "$SYSTEMCTL_ENABLED" = true ]
    else
        [ ! -f "$NFT_TABLE" ] && [ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ ! -e "$HY2_SERVICE_FILE" ]
        [ "$SYSTEMCTL_ACTIVE" = false ] && [ "$SYSTEMCTL_ENABLED" = false ]
    fi
}

run_transaction_failure() {
    local old_mode="$1" failure="$2" new_mode before_config before_cache before_protocols before_uri
    if [ "$old_mode" = external ]; then new_mode=nftables; else new_mode=external; fi
    init_case "tx-${old_mode}-${failure}" "$old_mode"
    prepare_transaction "$new_mode"
    before_config="$CASE_DIR/config.before"; before_cache="$CASE_DIR/cache.before"
    before_protocols="$CASE_DIR/protocols.before"; before_uri="$CASE_DIR/uri.before"
    cp "$CONFIG_PATH" "$before_config"; cp "$CACHE_FILE" "$before_cache"
    cp "$CONFIG_DIR/.protocols" "$before_protocols"; cp "$CONFIG_DIR/uris.txt" "$before_uri"
    case "$failure" in
        config-write) FAIL_CP_DEST="$CONFIG_DIR/config.json.tmp.$$" ;;
        cache-write) FAIL_CP_DEST="$CONFIG_DIR/.config_cache.tmp.$$" ;;
        singbox-restart) SINGBOX_RESTART_FAIL=true ;;
        uri-generation) URI_FAIL=true ;;
        reconcile) SYSTEMCTL_HOP_RESTART_FAIL=true ;;
        reconcile-delete) : > "$NFT_DELETE_FAIL_ONCE_FILE" ;;
    esac
    if apply_protocol_transaction "$TX_CANDIDATE" "$TX_PROTOCOLS" "$TX_CACHE" "$TX_URI_BACKUP"; then
        printf '失败注入未传播：%s -> %s / %s\n' "$old_mode" "$failure" "$new_mode" >&2
        exit 1
    fi
    assert_restored_mode "$old_mode" "$before_config" "$before_cache" "$before_protocols" "$before_uri"
    if [ "$failure" = singbox-restart ] || [ "$failure" = uri-generation ] || [ "$failure" = reconcile-delete ]; then
        grep -q '^systemctl stop sb-deploy-hy2-hopping.service$' "$SYSTEMCTL_LOG"
    fi
    rm -rf "$TX_DIR"
}

# 两种旧模式的文件提交、服务重启和 URI 失败均必须恢复原状态。
for mode in external nftables; do
    for failure in config-write cache-write singbox-restart uri-generation; do
        run_transaction_failure "$mode" "$failure"
    done
done
run_transaction_failure external reconcile
run_transaction_failure nftables reconcile-delete

# 成功事务需完整完成 nftables 与 external 的双向切换。
for old_mode in external nftables; do
    if [ "$old_mode" = external ]; then new_mode=nftables; else new_mode=external; fi
    init_case "tx-success-${old_mode}" "$old_mode"
    prepare_transaction "$new_mode"
    apply_protocol_transaction "$TX_CANDIDATE" "$TX_PROTOCOLS" "$TX_CACHE" "$TX_URI_BACKUP"
    [ "$(awk -F= '$1=="HY2_HOPPING_FORWARD_MODE" {print $2}' "$CACHE_FILE")" = "$new_mode" ]
    [ "$(jq -r '.inbounds[0].users[0].password' "$CONFIG_PATH")" = new-password ]
    [ "$(<"$CONFIG_DIR/uris.txt")" = generated-uri ]
    if [ "$new_mode" = nftables ]; then
        [ -f "$NFT_TABLE" ] && [ -x "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ -e "$HY2_SERVICE_FILE" ]
        [ "$SYSTEMCTL_ACTIVE" = true ] && [ "$SYSTEMCTL_ENABLED" = true ]
    else
        [ ! -f "$NFT_TABLE" ] && [ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ ! -e "$HY2_SERVICE_FILE" ]
        [ "$SYSTEMCTL_ACTIVE" = false ] && [ "$SYSTEMCTL_ENABLED" = false ]
    fi
    rm -rf "$TX_DIR"
done

# 关闭跳跃与删除 HY2 均使用事务协调器清理 nftables 或 external 残留。
for mode in nftables external; do
    for shape in closed deleted; do
        init_case "cleanup-${mode}-${shape}" "$mode"
        prepare_transaction "$mode" "$shape"
        before_config="$CASE_DIR/config.before"; before_cache="$CASE_DIR/cache.before"
        cp "$CONFIG_PATH" "$before_config"; cp "$CACHE_FILE" "$before_cache"
        apply_protocol_transaction "$TX_CANDIDATE" "$TX_PROTOCOLS" "$TX_CACHE" "$TX_URI_BACKUP"
        [ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ ! -e "$HY2_SERVICE_FILE" ]
        if [ "$mode" = nftables ]; then
            [ ! -f "$NFT_TABLE" ]
            grep -q 'nft delete table inet sb_deploy_hy2' "$NFT_LOG"
        else
            ! grep -Eq 'nft (-f -|delete table)' "$NFT_LOG"
        fi
        rm -rf "$TX_DIR"
    done
done

# OpenRC 创建中途失败必须撤销 helper、init、runlevel 和规则。
for failure in add restart helper-write init-write; do
    init_case "openrc-$failure" external
    OS=alpine
    sed -i.bak 's/HY2_HOPPING_FORWARD_MODE=external/HY2_HOPPING_FORWARD_MODE=nftables/' "$CACHE_FILE"
    read_config
    RC_ACTIVE=false RC_ADD_FAIL=false RC_RESTART_FAIL=false
    export RC_ACTIVE RC_ADD_FAIL RC_RESTART_FAIL
    if [ "$failure" = helper-write ]; then CONFIG_DIR="$CASE_DIR/missing/config"; fi
    if [ "$failure" = init-write ]; then HY2_SERVICE_FILE="$CASE_DIR/missing/init/sb-deploy-hy2-hopping"; fi
    [ "$failure" = add ] && RC_ADD_FAIL=true
    [ "$failure" = restart ] && RC_RESTART_FAIL=true
    if reconcile_hy2_hopping_runtime; then printf 'OpenRC 故障注入未传播: %s\n' "$failure" >&2; exit 1; fi
    [ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ]
    [ ! -e "$CONFIG_DIR/hy2-port-hopping.sh.tmp.$$" ]
    [ ! -e "$HY2_SERVICE_FILE" ]
    [ ! -e "$HY2_SERVICE_FILE.tmp.$$" ]
    [ ! -L "$RUNLEVEL_FILE" ]
    [ ! -f "$NFT_TABLE" ]
done

# Failed 的旧 Systemd/OpenRC 残留可在无 nft 权限时清理；active 且 helper clear 失败则保留证据。
init_case failed-systemd external
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 9\n' "$CASE_DIR/helper-called" > "$CONFIG_DIR/hy2-port-hopping.sh"
chmod +x "$CONFIG_DIR/hy2-port-hopping.sh"
printf 'failed-unit\n' > "$HY2_SERVICE_FILE"
NFT_ACCESS=false
SYSTEMCTL_ENABLED=true SYSTEMCTL_ACTIVE=false
: > "$NFT_LOG"
read_config
reconcile_hy2_hopping_runtime
[ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ ! -e "$HY2_SERVICE_FILE" ]
[ ! -e "$CASE_DIR/helper-called" ] && [ ! -s "$NFT_LOG" ]

init_case failed-openrc external
OS=alpine RC_ACTIVE=false
export RC_ACTIVE
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 9\n' "$CASE_DIR/helper-called" > "$CONFIG_DIR/hy2-port-hopping.sh"
chmod +x "$CONFIG_DIR/hy2-port-hopping.sh"
printf 'failed-init\n' > "$HY2_SERVICE_FILE"
ln -sf enabled "$RUNLEVEL_FILE"
NFT_ACCESS=false
: > "$NFT_LOG"
read_config
reconcile_hy2_hopping_runtime
[ ! -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ ! -e "$HY2_SERVICE_FILE" ] && [ ! -L "$RUNLEVEL_FILE" ]
[ ! -e "$CASE_DIR/helper-called" ] && [ ! -s "$NFT_LOG" ]

init_case active-clear-fail external
printf '#!/usr/bin/env bash\nexit 1\n' > "$CONFIG_DIR/hy2-port-hopping.sh"
chmod +x "$CONFIG_DIR/hy2-port-hopping.sh"
printf 'active-unit\n' > "$HY2_SERVICE_FILE"
: > "$NFT_TABLE"
NFT_ACCESS=false SYSTEMCTL_ENABLED=true SYSTEMCTL_ACTIVE=true
read_config
if reconcile_hy2_hopping_runtime; then printf 'active clear 失败时 external 错误地成功\n' >&2; exit 1; fi
[ -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ -e "$HY2_SERVICE_FILE" ] && [ -f "$NFT_TABLE" ]
grep -q '^systemctl stop sb-deploy-hy2-hopping.service$' "$SYSTEMCTL_LOG"

init_case active-openrc-clear-fail external
OS=alpine RC_ACTIVE=true
export RC_ACTIVE
printf '#!/usr/bin/env bash\nexit 1\n' > "$CONFIG_DIR/hy2-port-hopping.sh"
chmod +x "$CONFIG_DIR/hy2-port-hopping.sh"
printf 'active-init\n' > "$HY2_SERVICE_FILE"
ln -sf enabled "$RUNLEVEL_FILE"
: > "$NFT_TABLE"
read_config
if reconcile_hy2_hopping_runtime; then printf 'active OpenRC clear 失败时 external 错误地成功\\n' >&2; exit 1; fi
[ -e "$CONFIG_DIR/hy2-port-hopping.sh" ] && [ -e "$HY2_SERVICE_FILE" ] && [ -L "$RUNLEVEL_FILE" ] && [ -f "$NFT_TABLE" ]
grep -q '^rc-service sb-deploy-hy2-hopping stop$' "$SYSTEMCTL_LOG"

# action_uninstall 必须先清理项目运行时；测试拦截真实系统路径写入。
init_case uninstall-nft nftables
rm() {
    local arg
    for arg in "$@"; do
        case "$arg" in /etc/*|/usr/*|/var/*|/root/*) return 0 ;; esac
    done
    command rm "$@"
}
service_stop() { :; }
apk() { :; }
action_uninstall <<< 'y'
[ ! -f "$NFT_TABLE" ]

init_case uninstall-external external
: > "$NFT_LOG"
action_uninstall <<< 'y'
! grep -Eq 'nft (-f -|delete table)' "$NFT_LOG"

echo '管理器 HY2 external/runtime transaction fixture 测试通过'
