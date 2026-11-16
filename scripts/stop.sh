#!/usr/bin/env bash
# 停止后台启动的实例：读取 run/<instance>.pid，发送 SIGTERM 并等待退出。
#
# 用法：scripts/stop.sh <instance> [--timeout 60]
# 前台运行的实例请直接在终端按 Ctrl+C。
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

INSTANCE="${1:-}"
[[ -n "$INSTANCE" ]] || die "用法：scripts/stop.sh <instance> [--timeout 60]"
shift
TIMEOUT=60

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="${2:-}"; shift ;;
    *)         die "未知参数：$1" ;;
  esac
  shift
done
is_uint "$TIMEOUT" || die "--timeout 必须为非负整数：$TIMEOUT"

PID_FILE="$(pid_file_path "$INSTANCE")"
[[ -f "$PID_FILE" ]] || die "未找到 PID 文件：${PID_FILE}（若为前台运行，请直接按 Ctrl+C）"

PID="$(cat "$PID_FILE")"
if ! kill -0 "$PID" 2>/dev/null; then
  log "进程 ${PID} 已不存在，清理 PID 文件"
  rm -f "$PID_FILE"
  exit 0
fi

log "向实例 ${INSTANCE}（PID ${PID}）发送 SIGTERM"
kill -TERM "$PID"

for ((i = 0; i < TIMEOUT; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    rm -f "$PID_FILE"
    log "实例 ${INSTANCE} 已停止"
    exit 0
  fi
  sleep 1
done

die "等待 ${TIMEOUT} 秒后进程 ${PID} 仍未退出，请人工检查（可用 npu-smi info 确认 NPU 占用）"
