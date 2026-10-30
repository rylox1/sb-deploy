#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
REPO="$TEST_DIR/repo"
PRISTINE_SRC="$TEST_DIR/pristine-src"
PRISTINE_OUTPUT="$TEST_DIR/pristine-output.sh"
mkdir -p "$REPO/scripts" "$PRISTINE_SRC"
cp "$ROOT_DIR/scripts/build.sh" "$REPO/scripts/build.sh"
cp -R "$ROOT_DIR/src/installer" "$ROOT_DIR/src/manager" "$ROOT_DIR/src/templates" "$PRISTINE_SRC/"
cp "$ROOT_DIR/install-singbox.sh" "$PRISTINE_OUTPUT"
reset_fixture() {
    rm -rf "$REPO/src"
    mkdir -p "$REPO/src"
    cp -R "$PRISTINE_SRC/installer" "$PRISTINE_SRC/manager" "$PRISTINE_SRC/templates" "$REPO/src/"
    cp "$PRISTINE_OUTPUT" "$REPO/install-singbox.sh"
}
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
run_build() { (cd "$REPO" && bash scripts/build.sh "$@"); }
run_build_limited() { (cd "$REPO" && FUNCNEST=32 bash scripts/build.sh "$@"); }
REAL_BASH="$(command -v bash)"
mkdir -p "$TEST_DIR/fake-bin"
cat > "$TEST_DIR/fake-bin/bash" <<'WRAPPER'
#!/bin/sh
for argument do
    case "$argument" in
        */.install-singbox.sh.*)
            printf '\nif then\n' >> "$argument"
            break
            ;;
    esac
done
exec "$REAL_BASH" "$@"
WRAPPER
chmod +x "$TEST_DIR/fake-bin/bash"
run_build_candidate_syntax_failure() {
    (cd "$REPO" && REAL_BASH="$REAL_BASH" PATH="$TEST_DIR/fake-bin:$PATH" bash scripts/build.sh)
}
assert_failure() {
    local expected="$1" expected_status="$2" runner="$3" output status
    shift 3
    cp "$REPO/install-singbox.sh" "$TEST_DIR/expected-output.sh"
    if output=$("$runner" "$@" 2>&1); then
        fail "构建应失败，预期错误: $expected"
    else
        status=$?
    fi
    [[ "$status" == "$expected_status" ]] || fail "失败状态错误: $expected（实际 $status，预期 $expected_status）"
    case "$output" in
        *"$expected"*) ;;
        *) printf '[FAIL] 未得到预期错误: %s\n实际输出: %s\n' "$expected" "$output" >&2; exit 1 ;;
    esac
    cmp -s "$TEST_DIR/expected-output.sh" "$REPO/install-singbox.sh" || fail "失败场景破坏发布文件: $expected"
    if find "$REPO" -maxdepth 1 -name '.install-singbox.sh.*' -print -quit | grep -q .; then
        fail "失败场景遗留候选文件: $expected"
    fi
}

reset_fixture
bash -n "$ROOT_DIR/scripts/build.sh"
while IFS= read -r -d '' source_file; do
    bash -n "$source_file" || fail "源码或模板 Bash 语法检查失败: $source_file"
done < <(find "$ROOT_DIR/src" -type f \( -name '*.sh' -o -name '*.sh.in' \) -print0)
run_build --check
cp "$REPO/install-singbox.sh" "$TEST_DIR/first.sh"
run_build
cmp -s "$TEST_DIR/first.sh" "$REPO/install-singbox.sh" || fail '重复构建产物不同'
run_build --check

# 每个负例都先恢复为干净源码和发布产物，再单独注入一种故障。
reset_fixture
printf '\n# 发布产物漂移\n' >> "$REPO/install-singbox.sh"
assert_failure '发布文件与源码构建结果不同步' 1 run_build --check

reset_fixture
printf '\n# 源码漂移\n' >> "$REPO/src/installer/entry.sh"
assert_failure '发布文件与源码构建结果不同步' 1 run_build --check

reset_fixture
assert_failure '仅接受一个参数' 2 run_build --help extra

reset_fixture
assert_failure '未知参数: --unknown' 2 run_build --unknown

reset_fixture
rm "$REPO/src/templates/relay-install.sh"
assert_failure '缺少构建输入: src/templates/relay-install.sh' 1 run_build

reset_fixture
printf '\n@@BUILD:UNKNOWN_TOKEN@@\n' >> "$REPO/src/installer/entry.sh"
assert_failure '未知构建标记: UNKNOWN_TOKEN' 1 run_build

reset_fixture
grep -v '^@@BUILD:INSTALLER_INPUTS@@$' "$REPO/src/installer/main.sh.in" > "$TEST_DIR/main.sh.in.tmp"
mv "$TEST_DIR/main.sh.in.tmp" "$REPO/src/installer/main.sh.in"
assert_failure '构建标记次数错误: INSTALLER_INPUTS' 1 run_build

reset_fixture
printf '\n@@BUILD:MANAGER_CONTENT@@\n' >> "$REPO/src/installer/entry.sh"
assert_failure '重复或循环构建标记: MANAGER_CONTENT' 1 run_build

reset_fixture
printf '\n@@BUILD:MANAGER_CONTENT@@\n' >> "$REPO/src/manager/bootstrap.sh"
assert_failure '重复或循环构建标记: MANAGER_CONTENT' 1 run_build_limited

reset_fixture
printf '\n@@BUILD:INCOMPLETE\n' >> "$REPO/src/installer/entry.sh"
assert_failure '无效或未完整的构建标记: src/installer/entry.sh' 1 run_build

reset_fixture
printf '\nif then\n' >> "$REPO/src/manager/bootstrap.sh"
assert_failure '构建输入 Bash 语法检查失败: src/manager/bootstrap.sh' 1 run_build

reset_fixture
assert_failure '构建产物 Bash 语法检查失败' 1 run_build_candidate_syntax_failure

printf '构建器回归测试通过\n'
