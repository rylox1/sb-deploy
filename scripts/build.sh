#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT_DIR/install-singbox.sh"
MODE=build

usage() {
    printf '用法: bash scripts/build.sh [--check|--help]\n\n'
    printf '离线构建 install-singbox.sh，或检查源码与发布文件是否一致。\n'
}

if (( $# > 1 )); then
    printf '[ERR] 仅接受一个参数\n' >&2
    usage >&2
    exit 2
fi
case "${1:-}" in
    "") ;;
    --check) MODE=check ;;
    --help) usage; exit 0 ;;
    *) printf '[ERR] 未知参数: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

required_files=(
    src/installer/bootstrap.sh
    src/installer/main.sh.in
    src/installer/dependencies.sh
    src/installer/inputs.sh
    src/installer/binary.sh
    src/installer/config.sh
    src/installer/services.sh.in
    src/installer/links-and-summary.sh
    src/installer/manager-generator.sh.in
    src/installer/entry.sh
    src/manager/bootstrap.sh
    src/manager/services.sh
    src/manager/config.sh
    src/manager/actions.sh
    src/manager/relay.sh.in
    src/manager/protocols.sh
    src/manager/entry.sh
    src/templates/docker-compose-refresh.sh
    src/templates/relay-install.sh
)
for path in "${required_files[@]}"; do
    if [[ ! -f "$ROOT_DIR/$path" ]]; then
        printf '[ERR] 缺少构建输入: %s\n' "$path" >&2
        exit 1
    fi
    if ! bash -n "$ROOT_DIR/$path"; then
        printf '[ERR] 构建输入 Bash 语法检查失败: %s\n' "$path" >&2
        exit 1
    fi
done

declare -A marker_counts=()
expected_markers=(
    INSTALLER_DEPENDENCIES INSTALLER_INPUTS INSTALLER_BINARY INSTALLER_CONFIG
    INSTALLER_SERVICES INSTALLER_LINKS DOCKER_COMPOSE_TEMPLATE MANAGER_CONTENT
    RELAY_TEMPLATE
)

# 按固定映射展开文本，不执行或解释源码片段。
expand_file() {
    local relative="$1" destination="$2" line token
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^@@BUILD:([A-Z_]+)@@$ ]]; then
            token="${BASH_REMATCH[1]}"
            emit_token "$token" "$destination"
        elif [[ "$line" == *'@@BUILD:'* ]]; then
            printf '[ERR] 无效或未完整的构建标记: %s\n' "$relative" >&2
            return 1
        else
            printf '%s\n' "$line" >> "$destination"
        fi
    done < "$ROOT_DIR/$relative"
}

emit_files() {
    local destination="$1" path
    shift
    for path in "$@"; do
        expand_file "$path" "$destination"
    done
}

emit_token() {
    local token="$1" destination="$2"
    case "$token" in
        INSTALLER_DEPENDENCIES|INSTALLER_INPUTS|INSTALLER_BINARY|INSTALLER_CONFIG|INSTALLER_SERVICES|INSTALLER_LINKS|DOCKER_COMPOSE_TEMPLATE|RELAY_TEMPLATE|MANAGER_CONTENT) ;;
        *) printf '[ERR] 未知构建标记: %s\n' "$token" >&2; return 1 ;;
    esac
    if [[ "${marker_counts["$token"]:-0}" != 0 ]]; then
        printf '[ERR] 重复或循环构建标记: %s\n' "$token" >&2
        return 1
    fi
    marker_counts["$token"]=1
    case "$token" in
        INSTALLER_DEPENDENCIES) emit_files "$destination" src/installer/dependencies.sh ;;
        INSTALLER_INPUTS) emit_files "$destination" src/installer/inputs.sh ;;
        INSTALLER_BINARY) emit_files "$destination" src/installer/binary.sh ;;
        INSTALLER_CONFIG) emit_files "$destination" src/installer/config.sh ;;
        INSTALLER_SERVICES) emit_files "$destination" src/installer/services.sh.in ;;
        INSTALLER_LINKS) emit_files "$destination" src/installer/links-and-summary.sh ;;
        DOCKER_COMPOSE_TEMPLATE) emit_files "$destination" src/templates/docker-compose-refresh.sh ;;
        RELAY_TEMPLATE) emit_files "$destination" src/templates/relay-install.sh ;;
        MANAGER_CONTENT)
            emit_files "$destination" \
                src/manager/bootstrap.sh \
                src/manager/services.sh \
                src/manager/config.sh \
                src/manager/actions.sh \
                src/manager/relay.sh.in \
                src/manager/protocols.sh \
                src/manager/entry.sh
            ;;
    esac
}

candidate="$(mktemp "$ROOT_DIR/.install-singbox.sh.XXXXXX")"
cleanup() { rm -f "$candidate"; }
handle_signal() {
    local signal="$1" status="$2"
    trap - "$signal"
    printf '[ERR] 构建被信号中断: %s\n' "$signal" >&2
    exit "$status"
}
trap cleanup EXIT
trap 'handle_signal HUP 129' HUP
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

emit_files "$candidate" \
    src/installer/bootstrap.sh \
    src/installer/main.sh.in \
    src/installer/manager-generator.sh.in \
    src/installer/entry.sh

for token in "${expected_markers[@]}"; do
    if [[ "${marker_counts[$token]:-0}" != 1 ]]; then
        printf '[ERR] 构建标记次数错误: %s（期望 1，实际 %s）\n' "$token" "${marker_counts[$token]:-0}" >&2
        exit 1
    fi
done
if grep -Eq '@@BUILD:' "$candidate"; then
    printf '[ERR] 构建产物仍包含未展开标记\n' >&2
    exit 1
fi
if ! bash -n "$candidate"; then
    printf '[ERR] 构建产物 Bash 语法检查失败\n' >&2
    exit 1
fi

if [[ "$MODE" == check ]]; then
    if [[ ! -f "$OUTPUT" ]] || ! cmp -s "$candidate" "$OUTPUT"; then
        printf '[ERR] 发布文件与源码构建结果不同步\n' >&2
        exit 1
    fi
    printf '发布文件与源码一致。\n'
else
    if [[ -e "$OUTPUT" ]]; then
        current_mode="$(stat -f '%Lp' "$OUTPUT" 2>/dev/null || stat -c '%a' "$OUTPUT")"
        chmod "$current_mode" "$candidate"
    else
        chmod 755 "$candidate"
    fi
    mv -f "$candidate" "$OUTPUT"
    printf '已构建 %s\n' "$OUTPUT"
fi
