#!/usr/bin/env bash
# 轮询实例的 /v1/models 接口，直到服务就绪或超时。
# 模型加载通常需要 1-10 分钟，默认超时 900 秒。
#
# 用法：scripts/health_check.sh <instance> [--timeout 900]
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INSTANCE="${1:-}"
shift || true
TIMEOUT=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}"; shift ;;
    *)         die "未知参数：$1" ;;
  esac
  shift
done
is_uint "$TIMEOUT" || die "--timeout 必须为非负整数：$TIMEOUT"

load_config "$INSTANCE"
URL="http://${HOST}:${PORT}/v1/models"

elapsed=0
until curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; do
  if (( elapsed >= TIMEOUT )); then
    die "等待 ${TIMEOUT} 秒后 ${URL} 仍不可用，请查看日志：$(log_file_path "$INSTANCE")"
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done

log "实例 ${INSTANCE} 就绪（用时约 ${elapsed} 秒）：${URL}"
curl -fsS --max-time 5 "$URL"
echo
