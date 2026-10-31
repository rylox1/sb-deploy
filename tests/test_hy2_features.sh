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

# 从真实安装器源码提取转发状态与交互函数，独立验证不依赖首装流程。
for function_name in normalize_hy2_forward_mode probe_nftables_access select_hy2_forward_mode confirm_external_forwarding; do
    awk -v name="$function_name" '$0 ~ "^" name "\\(\\) \\{$" {copying=1} copying {print} copying && /^}$/ {exit}' \
        "$ROOT_DIR/src/installer/inputs.sh" >> "$TMP_DIR/installer-forwarding-functions.sh"
done
# shellcheck source=/dev/null
source "$TMP_DIR/installer-forwarding-functions.sh"
[ "$(normalize_hy2_forward_mode '' true host)" = nftables ]
[ -z "$(normalize_hy2_forward_mode external false host)" ]
[ -z "$(normalize_hy2_forward_mode external true docker)" ]
if normalize_hy2_forward_mode invalid true host >/dev/null 2>&1; then
    echo '错误地接受了无效 HY2 转发模式' >&2
    exit 1
fi

nft() { [ "${NFT_PROBE_AVAILABLE:-false}" = true ]; }
NFT_PROBE_AVAILABLE=true
probe_nftables_access
NFT_PROBE_AVAILABLE=false
if probe_nftables_access; then echo 'nftables EPERM 探测错误地成功' >&2; exit 1; fi
unset -f nft
mkdir -p "$TMP_DIR/no-nft-bin"
old_path=$PATH
PATH="$TMP_DIR/no-nft-bin"
if probe_nftables_access; then echo 'nft 命令缺失探测错误地成功' >&2; exit 1; fi
PATH=$old_path
if select_hy2_forward_mode <<< $'\n1\n2'; then :; else echo '无权限选择菜单意外取消' >&2; exit 1; fi
[ "$HY2_HOPPING_FORWARD_MODE" = external ]
if confirm_external_forwarding 20010 20012 <<< 'n'; then echo 'external 取消确认错误地成功' >&2; exit 1; fi
external_prompt=$(confirm_external_forwarding 20010 20012 <<< 'Y')
[[ "$external_prompt" == *'UDP 20010-20012 -> 容器 UDP 20010'* ]]
[[ "$external_prompt" == *'20010-20012:20010-20012/udp'* ]]

# 从安装器模板提取实际运行时函数，并用临时路径及服务 mock 验证清理/回滚。
awk '
    /^hy2_hopping_helper_path\(\)/ { copying=1 }
    /^# 设置服务$/ { exit }
    copying { print }
' "$ROOT_DIR/src/installer/services.sh.in" > "$TMP_DIR/installer-runtime-functions.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/installer-runtime-functions.sh"
RUNTIME_DIR="$TMP_DIR/runtime"
MOCK_BIN="$TMP_DIR/runtime-bin"
mkdir -p "$RUNTIME_DIR" "$MOCK_BIN"
RUNTIME_HELPER="$RUNTIME_DIR/hy2-port-hopping.sh"
RUNTIME_OPENRC="$RUNTIME_DIR/init-sb-deploy-hy2-hopping"
RUNTIME_UNIT="$RUNTIME_DIR/sb-deploy-hy2-hopping.service"
RUNTIME_RUNLEVEL="$RUNTIME_DIR/runlevel-sb-deploy-hy2-hopping"
NFT_LOG="$TMP_DIR/runtime-nft.log"
SERVICE_LOG="$TMP_DIR/runtime-service.log"
export NFT_LOG SERVICE_LOG RUNTIME_RUNLEVEL
hy2_hopping_helper_path() { printf '%s\n' "$RUNTIME_HELPER"; }
hy2_hopping_openrc_path() { printf '%s\n' "$RUNTIME_OPENRC"; }
hy2_hopping_systemd_path() { printf '%s\n' "$RUNTIME_UNIT"; }
hy2_hopping_runlevel_path() { printf '%s\n' "$RUNTIME_RUNLEVEL"; }
cat > "$MOCK_BIN/nft" <<'NFT_MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NFT_LOG"
if [ "$*" = 'list tables' ]; then [ "${NFT_DENY:-false}" = false ]; exit $?; fi
if [ "$*" = '-f -' ]; then while IFS= read -r _; do :; done; fi
exit 0
NFT_MOCK
cat > "$MOCK_BIN/rc-service" <<'RC_SERVICE_MOCK'
#!/usr/bin/env bash
printf 'rc-service %s\n' "$*" >> "$SERVICE_LOG"
case "${2:-}" in
  status) [ "${RC_ACTIVE:-false}" = true ] ;;
  start) [ "${RC_START_FAIL:-false}" = false ] ;;
  *) exit 0 ;;
esac
RC_SERVICE_MOCK
cat > "$MOCK_BIN/rc-update" <<'RC_UPDATE_MOCK'
#!/usr/bin/env bash
printf 'rc-update %s\n' "$*" >> "$SERVICE_LOG"
case "${1:-}" in
  add)
    [ "${RC_ADD_FAIL:-false}" = false ] || exit 1
    ln -sf fixture "$RUNTIME_RUNLEVEL"
    ;;
  del) rm -f "$RUNTIME_RUNLEVEL" ;;
esac
RC_UPDATE_MOCK
cat > "$MOCK_BIN/systemctl" <<'SYSTEMCTL_MOCK'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$SERVICE_LOG"
case "${1:-}" in
  is-enabled) [ "${SYSTEMD_ENABLED:-false}" = true ] ;;
  is-active) [ "${SYSTEMD_ACTIVE:-false}" = true ] ;;
  enable) [ "${SYSTEMD_ENABLE_FAIL:-false}" = false ] ;;
  restart) [ "${SYSTEMD_RESTART_FAIL:-false}" = false ] ;;
  *) exit 0 ;;
esac
SYSTEMCTL_MOCK
chmod +x "$MOCK_BIN"/*
old_runtime_path=$PATH
PATH="$MOCK_BIN:$PATH"
unset -f nft

# external 初装不触碰 nft 或创建本机运行时文件。
CONFIG_DIR="$RUNTIME_DIR/config-external"
mkdir -p "$CONFIG_DIR"
OS=alpine DEPLOY_MODE=host ENABLE_HY2=true HY2_HOPPING_ENABLED=true HY2_HOPPING_FORWARD_MODE=external
: > "$NFT_LOG"; : > "$SERVICE_LOG"
setup_hy2_hopping_runtime
[ ! -s "$NFT_LOG" ] && [ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_OPENRC" ] && [ ! -e "$RUNTIME_UNIT" ]

# external 重装清理 inactive OpenRC 残留，不调用遗留 helper。
mkdir -p "$(dirname "$RUNTIME_HELPER")"
printf '#!/usr/bin/env bash\nprintf called >> "%s"\nexit 1\n' "$TMP_DIR/helper-called" > "$RUNTIME_HELPER"
chmod +x "$RUNTIME_HELPER"
printf failed > "$RUNTIME_OPENRC"
ln -sf fixture "$RUNTIME_RUNLEVEL"
: > "$SERVICE_LOG"; : > "$NFT_LOG"
RC_ACTIVE=false; export RC_ACTIVE
cleanup_hy2_hopping_runtime false
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_OPENRC" ] && [ ! -L "$RUNTIME_RUNLEVEL" ]
[ ! -e "$TMP_DIR/helper-called" ] && [ ! -s "$NFT_LOG" ]

# active 服务清理失败时保留证据并给出人工处理提示。
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 1\n' "$SERVICE_LOG" > "$RUNTIME_HELPER"
chmod +x "$RUNTIME_HELPER"
printf active > "$RUNTIME_OPENRC"
ln -sf fixture "$RUNTIME_RUNLEVEL"
RC_ACTIVE=true; export RC_ACTIVE
if cleanup_hy2_hopping_runtime false 2>"$TMP_DIR/cleanup-error"; then
    echo 'active OpenRC 清理失败时错误地报告成功' >&2; exit 1
fi
grep -q '请人工检查' "$TMP_DIR/cleanup-error"
[ -e "$RUNTIME_HELPER" ] && [ -e "$RUNTIME_OPENRC" ] && [ -L "$RUNTIME_RUNLEVEL" ]
rm -f "$RUNTIME_HELPER" "$RUNTIME_OPENRC" "$RUNTIME_RUNLEVEL"
RC_ACTIVE=false; export RC_ACTIVE

# OpenRC 的 runlevel 添加、服务启动及 helper 写入失败均回滚残留。
CONFIG_DIR="$RUNTIME_DIR/config-openrc"
mkdir -p "$CONFIG_DIR"
OS=alpine DEPLOY_MODE=host ENABLE_HY2=true HY2_HOPPING_ENABLED=true HY2_HOPPING_FORWARD_MODE=nftables
: > "$SERVICE_LOG"; : > "$NFT_LOG"
RC_ADD_FAIL=true; export RC_ADD_FAIL
if setup_hy2_hopping_runtime; then echo 'OpenRC rc-update 失败未传播' >&2; exit 1; fi
RC_ADD_FAIL=false; export RC_ADD_FAIL
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_OPENRC" ] && [ ! -L "$RUNTIME_RUNLEVEL" ]
: > "$SERVICE_LOG"; : > "$NFT_LOG"
RC_START_FAIL=true; export RC_START_FAIL
if setup_hy2_hopping_runtime; then echo 'OpenRC 服务启动失败未传播' >&2; exit 1; fi
RC_START_FAIL=false; export RC_START_FAIL
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_OPENRC" ] && [ ! -L "$RUNTIME_RUNLEVEL" ]
BAD_HELPER="$RUNTIME_DIR/no-such-directory/helper"
hy2_hopping_helper_path() { printf '%s\n' "$BAD_HELPER"; }
if setup_hy2_hopping_runtime 2>/dev/null; then echo 'helper 写入失败未传播' >&2; exit 1; fi
[ ! -e "$RUNTIME_OPENRC" ] && [ ! -L "$RUNTIME_RUNLEVEL" ]
hy2_hopping_helper_path() { printf '%s\n' "$RUNTIME_HELPER"; }

# Systemd 的 enable/restart 失败均停用、停止并移除本项目文件。
CONFIG_DIR="$RUNTIME_DIR/config-systemd"
mkdir -p "$CONFIG_DIR"
OS=debian DEPLOY_MODE=host ENABLE_HY2=true HY2_HOPPING_ENABLED=true HY2_HOPPING_FORWARD_MODE=nftables
: > "$SERVICE_LOG"; : > "$NFT_LOG"
SYSTEMD_ENABLE_FAIL=true; export SYSTEMD_ENABLE_FAIL
if setup_hy2_hopping_runtime; then echo 'Systemd enable 失败未传播' >&2; exit 1; fi
SYSTEMD_ENABLE_FAIL=false; export SYSTEMD_ENABLE_FAIL
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_UNIT" ]
grep -q 'systemctl stop sb-deploy-hy2-hopping.service' "$SERVICE_LOG"
grep -q 'systemctl disable sb-deploy-hy2-hopping.service' "$SERVICE_LOG"
: > "$SERVICE_LOG"; : > "$NFT_LOG"
SYSTEMD_RESTART_FAIL=true; export SYSTEMD_RESTART_FAIL
if setup_hy2_hopping_runtime; then echo 'Systemd restart 失败未传播' >&2; exit 1; fi
SYSTEMD_RESTART_FAIL=false; export SYSTEMD_RESTART_FAIL
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_UNIT" ]
grep -q 'systemctl stop sb-deploy-hy2-hopping.service' "$SERVICE_LOG"
grep -q 'systemctl disable sb-deploy-hy2-hopping.service' "$SERVICE_LOG"
: > "$SERVICE_LOG"
cleanup_hy2_hopping_runtime false
! grep -q 'systemctl daemon-reload' "$SERVICE_LOG"
PATH=$old_runtime_path
CONFIG_DIR="$TMP_DIR/config" OS=unknown DEPLOY_MODE=host

# 从安装器源码提取真实 get_config/create_config，验证初装确认、缓存和 listen_port。
awk '/^get_config\(\)/ { copying=1 } copying { print } copying && /^}$/ { exit }' "$ROOT_DIR/src/installer/inputs.sh" > "$TMP_DIR/installer-get-config.sh"
awk '/^create_config\(\)/ { copying=1 } /^# 调用配置生成/ { exit } copying { print }' "$ROOT_DIR/src/installer/config.sh" > "$TMP_DIR/installer-create-config.sh"
run_installer_config_fixture() {
    local case_dir="$1" mode="$2" answers="$3" deny_nft="$4"
    (
        mkdir -p "$case_dir"
        CONFIG_DIR="$case_dir" CONFIG_PATH="$case_dir/config.json" CACHE_FILE="$case_dir/.config_cache"
        DEPLOY_MODE="$mode" OS=alpine
        ENABLE_SS=false ENABLE_HY2=true ENABLE_TUIC=false ENABLE_REALITY=false ENABLE_ANYTLS=false
        LOG_ENABLED=false LOG_DISABLED_JSON=true CUSTOM_IP="" SS_METHOD="2022-blake3-aes-128-gcm"
        SINGBOX_PORT_HY2=20010
        PATH="$MOCK_BIN:$old_runtime_path" NFT_DENY="$deny_nft"
        export PATH NFT_DENY
        source "$TMP_DIR/installer-forwarding-functions.sh"
        source "$TMP_DIR/installer-get-config.sh"
        source "$TMP_DIR/installer-create-config.sh"
        info() { :; }
        warn() { :; }
        err() { printf '[ERR] %s\n' "$*" >&2; }
        rand_pass() { printf 'fixture-hy2-password'; }
        run_singbox() { return 0; }
        sed() {
            if [ "${1:-}" = -i ]; then
                local expression="$2" file="$3"
                perl -pi -e "$expression" "$file"
            else
                command sed "$@"
            fi
        }
        get_config <<< "$answers"
        create_config
        printf '%s\n' "$PORT_HY2" > "$case_dir/listen-port.txt"
    )
}
run_installer_config_fixture "$TMP_DIR/install-external" host $'y\n20010-20012\n15\n2\ny\nn' true > "$TMP_DIR/install-external.out"
grep -q '^HY2_HOPPING_FORWARD_MODE=external$' "$TMP_DIR/install-external/.config_cache"
[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$TMP_DIR/install-external/config.json")" = 20010 ]
run_installer_config_fixture "$TMP_DIR/install-external-after-reject" host $'y\n20010-20012\n15\n1\n2\ny\nn' true > "$TMP_DIR/install-external-after-reject.out"
grep -q '^HY2_HOPPING_FORWARD_MODE=external$' "$TMP_DIR/install-external-after-reject/.config_cache"
if run_installer_config_fixture "$TMP_DIR/install-rejected" host $'y\n20010-20012\n15\n2\nn' true > "$TMP_DIR/install-rejected.out" 2>&1; then
    echo '拒绝 external 确认后安装流程错误地成功' >&2; exit 1
fi
[ ! -e "$TMP_DIR/install-rejected/config.json" ]
: > "$NFT_LOG"
if run_installer_config_fixture "$TMP_DIR/install-nft-denied" host $'y\n20010-20012\n15\n1\nq\nn' true > "$TMP_DIR/install-nft-denied.out" 2>&1; then
    echo '无权限时选择 nftables 并取消应中止初装' >&2; exit 1
fi
[ ! -e "$TMP_DIR/install-nft-denied/config.json" ]
[ ! -e "$RUNTIME_HELPER" ] && [ ! -e "$RUNTIME_OPENRC" ] && [ ! -e "$RUNTIME_UNIT" ]
! grep -Eq '(-f -|delete table)' "$NFT_LOG"
run_installer_config_fixture "$TMP_DIR/install-docker" docker $'y\n20010-20012\n15\nn' false > "$TMP_DIR/install-docker.out"
! grep -q '选择 HY2 端口跳跃转发方式' "$TMP_DIR/install-docker.out"
! grep -q '^HY2_HOPPING_FORWARD_MODE=' "$TMP_DIR/install-docker/.config_cache"
[ "$(jq -r '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$TMP_DIR/install-docker/config.json")" = 20010 ]

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
{"inbounds":[{"type":"shadowsocks","tag":"ss-in","listen":"::","listen_port":20999,"method":"aes-128-gcm","password":"stable-ss-password"},{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":20000,"ignore_client_bandwidth":true,"up_mbps":50,"down_mbps":80,"users":[{"password":"secret:+/=?&@#"}],"tls":{"enabled":true,"alpn":["h3"]}}],"outbounds":[{"type":"direct"}]}
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
URI_NFTABLES_BASELINE=$(<"$URI_FILE")
HY2_URI_BEFORE_MODE=$(grep '^hy2://' "$URI_FILE")
SS_URI_BEFORE_MODE=$(grep '^ss://' "$URI_FILE")
[ "$(grep -c '^hy2://' "$URI_FILE")" -eq 3 ]
printf '\nHY2_HOPPING_FORWARD_MODE=external\n' >> "$CONFIG_DIR/.config_cache"
generate_uris >/dev/null
[ "$(grep '^hy2://' "$URI_FILE")" = "$HY2_URI_BEFORE_MODE" ] || { echo 'HY2 转发模式改变了客户端 URI' >&2; exit 1; }
[ "$(grep '^ss://' "$URI_FILE")" = "$SS_URI_BEFORE_MODE" ] || { echo '外部转发说明改变了其他协议链接' >&2; exit 1; }
[ "$(grep -c '^hy2://' "$URI_FILE")" -eq 3 ] || { echo '外部转发说明被输出为客户端链接' >&2; exit 1; }
grep -q '^# 外部转发契约：UDP 20000-20002 -> 容器 UDP 20000$' "$URI_FILE"
grep -q '^# 配置整个 UDP 范围到单端口，或逐个外部 UDP 端口映射到容器 UDP 20000。$' "$URI_FILE"
grep -q '^# 不要使用 20000-20002:20000-20002/udp 一对一映射' "$URI_FILE"
grep -q '^# 脚本无法验证宿主机规则，请从容器外测试范围首端、中间端和末端。$' "$URI_FILE"
printf '\nHY2_HOPPING_FORWARD_MODE=nftables\n' >> "$CONFIG_DIR/.config_cache"
generate_uris >/dev/null
[ "$(<"$URI_FILE")" = "$URI_NFTABLES_BASELINE" ] || { echo 'nftables 模式的 uris.txt 输出发生变化' >&2; exit 1; }
printf '\nHY2_HOPPING_FORWARD_MODE=external\n' >> "$CONFIG_DIR/.config_cache"
DEPLOY_MODE=docker
generate_uris >/dev/null
[ "$(<"$URI_FILE")" = "$URI_NFTABLES_BASELINE" ] || { echo 'Docker 模式的 uris.txt 输出发生变化或包含 Host 转发契约' >&2; exit 1; }
DEPLOY_MODE=host
printf '\nHY2_HOPPING_FORWARD_MODE=nftables\n' >> "$CONFIG_DIR/.config_cache"
generate_uris >/dev/null
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

# 安装器与管理器都仅在 Host + 跳跃 + external 时附加非 URI 转发说明。
awk '/^generate_uris\(\)/ { copying=1 } copying { print } copying && /^}$/ { exit }' \
    "$ROOT_DIR/src/installer/links-and-summary.sh" | sed 's/^generate_uris()/generate_installer_uris()/' > "$TMP_DIR/installer-generate-uris.sh"
source "$TMP_DIR/installer-generate-uris.sh"
ENABLE_SS=false ENABLE_HY2=true ENABLE_TUIC=false ENABLE_REALITY=false ENABLE_ANYTLS=false
PUB_IP=2001:db8::1 suffix='' PSK_HY2='secret:+/=?&@#' PORT_HY2=20000
HY2_HOPPING_ENABLED=true HY2_HOP_START=20000 HY2_HOP_END=20002 HY2_HOP_INTERVAL=27
HY2_BRUTAL_ENABLED=true HY2_CLIENT_UP_MBPS=80 HY2_CLIENT_DOWN_MBPS=50
DEPLOY_MODE=host HY2_HOPPING_FORWARD_MODE=nftables
generate_installer_uris > "$TMP_DIR/installer-uris-nftables.txt"
INSTALLER_URI_BASELINE=$(<"$TMP_DIR/installer-uris-nftables.txt")
HY2_HOPPING_FORWARD_MODE=external
generate_installer_uris > "$TMP_DIR/installer-uris-external.txt"
[ "$(grep '^hy2://' "$TMP_DIR/installer-uris-external.txt")" = "$(grep '^hy2://' "$TMP_DIR/installer-uris-nftables.txt")" ]
[ "$(grep -c '^hy2://' "$TMP_DIR/installer-uris-external.txt")" -eq 3 ]
grep -q '^# 外部转发契约：UDP 20000-20002 -> 容器 UDP 20000$' "$TMP_DIR/installer-uris-external.txt"
grep -q '^# 不要使用 20000-20002:20000-20002/udp 一对一映射' "$TMP_DIR/installer-uris-external.txt"
grep -q '^# 脚本无法验证宿主机规则，请从容器外测试范围首端、中间端和末端。$' "$TMP_DIR/installer-uris-external.txt"
HY2_HOPPING_FORWARD_MODE=nftables
DEPLOY_MODE=docker
generate_installer_uris > "$TMP_DIR/installer-uris-docker.txt"
[ "$(<"$TMP_DIR/installer-uris-docker.txt")" = "$INSTALLER_URI_BASELINE" ] || { echo '安装器 Docker URI 输出被 Host 模式影响' >&2; exit 1; }
DEPLOY_MODE=host HY2_HOPPING_ENABLED=false HY2_HOPPING_FORWARD_MODE=nftables
generate_installer_uris > "$TMP_DIR/installer-uris-fixed.txt"
HY2_HOPPING_FORWARD_MODE=external
generate_installer_uris > "$TMP_DIR/installer-uris-fixed-external.txt"
[ "$(<"$TMP_DIR/installer-uris-fixed.txt")" = "$(<"$TMP_DIR/installer-uris-fixed-external.txt")" ] || { echo '安装器固定端口 URI 输出受 external 模式影响' >&2; exit 1; }
! grep -q '^# 外部转发契约' "$TMP_DIR/installer-uris-fixed.txt"
[ "$(grep '^hy2://' "$TMP_DIR/installer-uris-fixed.txt" | wc -l | tr -d ' ')" -eq 3 ]
HY2_HOPPING_ENABLED=true

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
grep -Fq -- '- "20999:20999/tcp"' "$COMPOSE_DIR/docker-compose.yml"
grep -Fq -- '- "20999:20999/udp"' "$COMPOSE_DIR/docker-compose.yml"
[ "$(grep -c '/udp' "$COMPOSE_DIR/docker-compose.yml")" -eq 4 ]
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

# 同时提取安装器与管理器实际 helper，比较项目表规则核心保持同步。
awk '/^setup_hy2_hopping_runtime\(\)/ { in_function=1 } in_function && /cat > "\$helper" <<\047HOPPING_SCRIPT\047/ { copying=1; next } copying && /^HOPPING_SCRIPT$/ { exit } copying { print }' \
    "$ROOT_DIR/src/installer/services.sh.in" > "$TMP_DIR/installer-hopping-helper.sh"
awk '/^ensure_hy2_hopping_runtime\(\)/ { in_function=1 } in_function && /cat > "\$helper_tmp" <<\047HOPPING_SCRIPT\047/ { copying=1; next } copying && /^HOPPING_SCRIPT$/ { exit } copying { print }' \
    "$ROOT_DIR/src/manager/services.sh" > "$TMP_DIR/manager-hopping-helper.sh"
[ -s "$TMP_DIR/installer-hopping-helper.sh" ] && [ -s "$TMP_DIR/manager-hopping-helper.sh" ] || { echo '未提取到安装器或管理器 Host helper' >&2; exit 1; }
sed -e 's/clear_rules/clear_table/g' -e 's/apply_rules/apply_table/g' \
    -e '/command -v nft .*启用 HY2 跳跃需要 nftables/d' \
    -e "s#  \*) echo '用法: hy2-port-hopping.sh apply|clear' >&2; exit 2 ;;#  *) exit 2 ;;#" \
    "$TMP_DIR/manager-hopping-helper.sh" > "$TMP_DIR/manager-hopping-helper.normalized.sh"
cmp -s "$TMP_DIR/installer-hopping-helper.sh" "$TMP_DIR/manager-hopping-helper.normalized.sh" || {
    echo '安装器与管理器 HY2 helper 的规则主体不一致' >&2
    diff -u "$TMP_DIR/installer-hopping-helper.sh" "$TMP_DIR/manager-hopping-helper.normalized.sh" >&2 || true
    exit 1
}

# Host nftables helper 仅触碰项目专属 inet 表，apply/clear 可重复执行。
cat > "$CONFIG_DIR/.config_cache" <<'CACHE'
CUSTOM_IP=example.test
LOG_ENABLED=false
HY2_HOPPING_ENABLED=true
HY2_HOP_START=21000
HY2_HOP_END=21002
HY2_HOP_INTERVAL=27
CACHE
awk '/^ensure_hy2_hopping_runtime\(\)/ { in_function=1 } in_function && /cat > "\$helper_tmp" <<\047HOPPING_SCRIPT\047/ { copying=1; next } copying && /^HOPPING_SCRIPT$/ { exit } copying { print }' "$ROOT_DIR/install-singbox.sh" > "$CONFIG_DIR/hy2-port-hopping.sh"
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
HY2_HOPPING_FORWARD_MODE=external
CACHE
DEPLOY_MODE=host
read_config
generate_uris
URI_FIXED_BASELINE=$(<"$URI_FILE")
! grep -E '^hy2://.*(hop-interval=|[?&]up=|[?&]down=)' "$URI_FILE"
! grep -q '^# 外部转发契约' "$URI_FILE"
grep -q 'ignore_client_bandwidth' < <(jq -r '.inbounds[]|select(.type=="hysteria2")|keys[]' "$CONFIG_DIR/config.json")
printf '\nHY2_HOPPING_FORWARD_MODE=nftables\n' >> "$CONFIG_DIR/.config_cache"
generate_uris
[ "$(<"$URI_FILE")" = "$URI_FIXED_BASELINE" ] || { echo '固定端口 nftables 缓存改变了 uris.txt' >&2; exit 1; }
printf '\nHY2_HOPPING_FORWARD_MODE=external\n' >> "$CONFIG_DIR/.config_cache"
generate_uris
[ "$(<"$URI_FILE")" = "$URI_FIXED_BASELINE" ] || { echo '固定端口 external 缓存改变了 uris.txt' >&2; exit 1; }
DEPLOY_MODE=docker

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
    export HY2_TEST_MIHOMO_URI="$mihomo" HY2_TEST_BBR_URI="$(awk '/^hy2:/ { print; exit }' "$URI_FILE")"
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

# 管理器转发状态、菜单与模式感知运行时回归。
MANAGER_FORWARD_DIR="$TMP_DIR/manager-forward"
mkdir -p "$MANAGER_FORWARD_DIR"
CONFIG_DIR="$MANAGER_FORWARD_DIR" CONFIG_PATH="$MANAGER_FORWARD_DIR/config.json" CACHE_FILE="$MANAGER_FORWARD_DIR/.config_cache"
DEPLOY_MODE=host OS=debian
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"hysteria2","listen":"::","listen_port":22000,"users":[{"password":"forward-secret"}],"ignore_client_bandwidth":true,"tls":{"enabled":true}}]}
JSON
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
CACHE
read_config
[ "$HY2_HOPPING_FORWARD_MODE" = nftables ] && [ "$HY2_HOPPING_FORWARD_MODE_LEGACY" = true ]
render_protocol_state "$CONFIG_PATH" "$MANAGER_FORWARD_DIR/protocols" "$MANAGER_FORWARD_DIR/rendered-cache"
grep -q '^HY2_HOPPING_FORWARD_MODE=nftables$' "$MANAGER_FORWARD_DIR/rendered-cache"
printf '\nHY2_HOPPING_FORWARD_MODE=invalid\n' >> "$CACHE_FILE"
if read_config >/dev/null 2>&1; then echo '管理器错误接受非法 HY2 转发模式' >&2; exit 1; fi
sed -i.bak '/HY2_HOPPING_FORWARD_MODE=/d' "$CACHE_FILE"
DEPLOY_MODE=docker
printf '\nHY2_HOPPING_FORWARD_MODE=invalid\n' >> "$CACHE_FILE"
read_config
[ -z "$HY2_HOPPING_FORWARD_MODE" ]
render_protocol_state "$CONFIG_PATH" "$MANAGER_FORWARD_DIR/docker-protocols" "$MANAGER_FORWARD_DIR/docker-cache"
! grep -q '^HY2_HOPPING_FORWARD_MODE=' "$MANAGER_FORWARD_DIR/docker-cache"
DEPLOY_MODE=host
sed -i.bak '/HY2_HOPPING_FORWARD_MODE=/d;s/HY2_HOPPING_ENABLED=true/HY2_HOPPING_ENABLED=false/' "$CACHE_FILE"
printf '\nHY2_HOPPING_FORWARD_MODE=invalid\n' >> "$CACHE_FILE"
read_config
[ -z "$HY2_HOPPING_FORWARD_MODE" ]
render_protocol_state "$CONFIG_PATH" "$MANAGER_FORWARD_DIR/closed-protocols" "$MANAGER_FORWARD_DIR/closed-cache"
grep -q "^HY2_HOPPING_FORWARD_MODE=''$" "$MANAGER_FORWARD_DIR/closed-cache"

# 还原生产管理器版本，避免上方 installer fixture 同名函数覆盖。
for function_name in normalize_hy2_forward_mode probe_nftables_access; do
    awk -v name="$function_name" '$0 ~ "^" name "\\(\\) \\{$" {copying=1} copying {print} copying && /^}$/ {exit}' \
        "$ROOT_DIR/src/manager/services.sh" >> "$TMP_DIR/manager-forward-functions.sh"
done
for function_name in select_hy2_forward_mode confirm_external_forwarding; do
    awk -v name="$function_name" '$0 ~ "^" name "\\(\\) \\{$" {copying=1} copying {print} copying && /^}$/ {exit}' \
        "$ROOT_DIR/src/manager/protocols.sh" >> "$TMP_DIR/manager-forward-functions.sh"
done
source "$TMP_DIR/manager-forward-functions.sh"
source "$ROOT_DIR/src/manager/services.sh"
FORWARD_LOG="$TMP_DIR/manager-forward.log"
: > "$FORWARD_LOG"
nft() {
    printf 'nft %s\n' "$*" >> "$FORWARD_LOG"
    case "$*" in 'list tables') [ "${NFT_ACCESS:-true}" = true ] || return 1; printf 'table inet sb_deploy_hy2\n';; '-f -') while IFS= read -r _; do :; done;; 'delete table inet sb_deploy_hy2') :;; *) return 1;; esac
}
NFT_ACCESS=true
HY2_HOPPING_FORWARD_MODE=""
select_hy2_forward_mode <<< '' > "$TMP_DIR/manager-menu-available.out" 2>&1
[ "$HY2_HOPPING_FORWARD_MODE" = nftables ]
NFT_ACCESS=false
HY2_HOPPING_FORWARD_MODE=""
select_hy2_forward_mode <<< $'\n1\n2' > "$TMP_DIR/manager-menu.out" 2>&1
[ "$HY2_HOPPING_FORWARD_MODE" = external ]
grep -q 'nftables 不可用' "$TMP_DIR/manager-menu.out"
if confirm_external_forwarding 22000 22002 <<< 'n'; then echo '管理器 external 的 n 确认错误地成功' >&2; exit 1; fi
confirm_external_forwarding 22000 22002 <<< 'y' > "$TMP_DIR/manager-external-prompt"
grep -q 'UDP 22000-22002 -> 容器 UDP 22000' "$TMP_DIR/manager-external-prompt"
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
CACHE
read_config
before_config=$(cksum "$CONFIG_PATH")
before_cache=$(cksum "$CACHE_FILE")
collect_hy2_settings 22000 <<< $'\n\n\n1\n2\nn'
[ "$HY2_SETTINGS_CANCELLED" = true ]
[ "$(cksum "$CONFIG_PATH")" = "$before_config" ] && [ "$(cksum "$CACHE_FILE")" = "$before_cache" ]
collect_hy2_settings 22000 <<< $'\n\n\n2\ny\nN' > "$TMP_DIR/manager-collect.out"
[ "$HY2_HOPPING_FORWARD_MODE" = external ]
[ "$HY2_HOPPING_ENABLED" = true ]
grep -q 'nftables（旧配置）' "$TMP_DIR/manager-collect.out"

MANAGER_RUNTIME="$TMP_DIR/manager-runtime"
mkdir -p "$MANAGER_RUNTIME"
CONFIG_DIR="$MANAGER_RUNTIME" CONFIG_PATH="$MANAGER_RUNTIME/config.json" CACHE_FILE="$MANAGER_RUNTIME/.config_cache"
HY2_HELPER="$MANAGER_RUNTIME/hy2-port-hopping.sh" HY2_SERVICE="$MANAGER_RUNTIME/sb-deploy-hy2-hopping.service"
hy2_hopping_service_file() { printf '%s\n' "$HY2_SERVICE"; }
cat > "$CONFIG_PATH" <<'JSON'
{"inbounds":[{"type":"hysteria2","listen":"::","listen_port":22000,"users":[{"password":"forward-secret"}],"ignore_client_bandwidth":true,"tls":{"enabled":true}}]}
JSON
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=external
CACHE
read_config
: > "$FORWARD_LOG"
reconcile_hy2_hopping_runtime
[ ! -s "$FORWARD_LOG" ] && [ ! -e "$HY2_HELPER" ] && [ ! -e "$HY2_SERVICE" ]

NFT_ACCESS=true
SYSTEMCTL_ENABLED=false SYSTEMCTL_ACTIVE=false SYSTEMCTL_ENABLE_FAIL=false SYSTEMCTL_RESTART_FAIL=false
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$FORWARD_LOG"
    case "$1" in
        is-enabled) [ "$SYSTEMCTL_ENABLED" = true ];;
        is-active) [ "$SYSTEMCTL_ACTIVE" = true ];;
        enable) [ "$SYSTEMCTL_ENABLE_FAIL" = false ] && SYSTEMCTL_ENABLED=true;;
        disable) SYSTEMCTL_ENABLED=false;;
        restart) [ "$SYSTEMCTL_RESTART_FAIL" = false ] && SYSTEMCTL_ACTIVE=true;;
        stop) SYSTEMCTL_ACTIVE=false;;
        *) return 0;;
    esac
}
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=nftables
CACHE
read_config
reconcile_hy2_hopping_runtime
[ -x "$HY2_HELPER" ] && [ -e "$HY2_SERVICE" ]
cp "$CONFIG_PATH" "$MANAGER_RUNTIME/config.before-external"
printf 'uri-snapshot\\n' > "$CONFIG_DIR/uris.txt"
cp "$CONFIG_DIR/uris.txt" "$MANAGER_RUNTIME/uris.before-external"
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=external
CACHE
read_config
: > "$FORWARD_LOG"
reconcile_hy2_hopping_runtime
[ ! -e "$HY2_HELPER" ] && [ ! -e "$HY2_SERVICE" ]
grep -q '^systemctl stop sb-deploy-hy2-hopping.service$' "$FORWARD_LOG"
cmp -s "$CONFIG_PATH" "$MANAGER_RUNTIME/config.before-external"
cmp -s "$CONFIG_DIR/uris.txt" "$MANAGER_RUNTIME/uris.before-external"
cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=nftables
CACHE
read_config
reconcile_hy2_hopping_runtime
[ -x "$HY2_HELPER" ] && [ -e "$HY2_SERVICE" ]
SYSTEMCTL_RESTART_FAIL=true
if reconcile_hy2_hopping_runtime; then echo 'systemd hopping restart 失败未传播' >&2; exit 1; fi
SYSTEMCTL_RESTART_FAIL=false
[ ! -e "$HY2_HELPER" ] && [ ! -e "$HY2_SERVICE" ]

cat > "$CACHE_FILE" <<'CACHE'
HY2_HOPPING_ENABLED=true
HY2_HOP_START=22000
HY2_HOP_END=22002
HY2_HOP_INTERVAL=15
HY2_HOPPING_FORWARD_MODE=external
CACHE
read_config
printf '#!/usr/bin/env bash\\nprintf called > "%s"\\n' "$TMP_DIR/historical-helper-called" > "$HY2_HELPER"
chmod +x "$HY2_HELPER"
: > "$FORWARD_LOG"
service_start
[ ! -e "$TMP_DIR/historical-helper-called" ]
! grep -q 'nft ' "$FORWARD_LOG"
! grep -q 'apply' "$FORWARD_LOG"

# Docker 协调器不得访问 Host service 路径。
DEPLOY_MODE=docker
hy2_hopping_service_file() { touch "$TMP_DIR/docker-forward-host-path-accessed"; printf '%s\n' "$HY2_SERVICE"; }
reconcile_hy2_hopping_runtime
[ ! -e "$TMP_DIR/docker-forward-host-path-accessed" ]
DEPLOY_MODE=host
echo 'HY2 功能 fixture 测试通过'
