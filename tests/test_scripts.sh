#!/usr/bin/env bash
# 脚本级测试：不需要 NPU 与 vLLM，只验证配置解析、参数组装和输入校验。
# 用法：bash tests/test_scripts.sh
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVE="${ROOT}/scripts/serve.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  [通过] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [失败] %s\n' "$1" >&2; }

assert_contains() {
  local name="$1" text="$2" pattern="$3"
  if grep -qF -- "$pattern" <<<"$text"; then pass "$name"; else fail "$name（缺少：$pattern）"; fi
}

assert_not_contains() {
  local name="$1" text="$2" pattern="$3"
  if grep -qF -- "$pattern" <<<"$text"; then fail "$name（不应包含：$pattern）"; else pass "$name"; fi
}

assert_fails() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name（本应失败但成功了）"; else pass "$name"; fi
}

echo "== 实例 A dry-run =="
out_a="$("$SERVE" a --dry-run)"
assert_contains "A 绑定 NPU 0" "$out_a" "ASCEND_RT_VISIBLE_DEVICES=0"
assert_contains "A 使用端口 8000" "$out_a" "--port 8000"
assert_contains "A 在线加载" "$out_a" "HF_HUB_OFFLINE=(unset)"
assert_contains "A 模型名正确" "$out_a" "serve Qwen/Qwen3-4B"
assert_contains "A 包含投机解码配置" "$out_a" "dspark"
assert_not_contains "A 不应出现端口 8001" "$out_a" "8001"

echo "== 实例 B dry-run =="
out_b="$("$SERVE" b --dry-run)"
assert_contains "B 绑定 NPU 1" "$out_b" "ASCEND_RT_VISIBLE_DEVICES=1"
assert_contains "B 使用端口 8001" "$out_b" "--port 8001"
assert_contains "B 离线加载" "$out_b" "HF_HUB_OFFLINE=1"
assert_not_contains "B 不应出现端口 8000" "$out_b" "--port 8000"

echo "== 输入校验 =="
assert_fails "未知实例名应失败" "$SERVE" no-such-instance --dry-run
assert_fails "缺少实例名应失败" "$SERVE" --dry-run
assert_fails "未知参数应失败" "$SERVE" a --bogus

# 用临时配置目录测试非法取值，避免修改仓库中的真实配置
TMP_CONF="$(mktemp -d)"
trap 'rm -rf "$TMP_CONF"' EXIT
mkdir -p "$TMP_CONF/instances"
cp "${ROOT}/configs/common.env" "$TMP_CONF/common.env"

make_bad_instance() {
  printf 'INSTANCE_NAME=bad\nNPU_ID=0\nPORT=%s\nHF_OFFLINE=0\n' "$1" >"$TMP_CONF/instances/bad.env"
}

make_bad_instance "abc"
assert_fails "非数字端口应失败" env CONFIG_DIR="$TMP_CONF" "$SERVE" bad --dry-run
make_bad_instance "80"
assert_fails "特权端口应失败" env CONFIG_DIR="$TMP_CONF" "$SERVE" bad --dry-run
make_bad_instance "8000"
out_ok="$(env CONFIG_DIR="$TMP_CONF" "$SERVE" bad --dry-run)"
assert_contains "合法临时配置可通过校验" "$out_ok" "PORT=8000"

echo
echo "结果：通过 ${PASS}，失败 ${FAIL}"
[[ "$FAIL" -eq 0 ]]
