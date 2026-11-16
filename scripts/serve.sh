#!/usr/bin/env bash
# 启动单个 vLLM-Ascend 实例。
#
# 用法：
#   scripts/serve.sh <instance>                前台运行，Ctrl+C 停止
#   scripts/serve.sh <instance> --background   后台运行，PID 写入 run/<instance>.pid，日志写入 logs/<instance>.log
#   scripts/serve.sh <instance> --dry-run      只打印生效的环境变量与命令，不需要 NPU 环境
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'EOF'
用法：scripts/serve.sh <instance> [--background | --dry-run]
  <instance>      实例名，对应 configs/instances/<instance>.env
  --background    后台运行
  --dry-run       仅打印配置与命令
EOF
}

INSTANCE="${1:-}"
[[ $# -gt 0 ]] && shift
MODE=foreground

while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) MODE=background ;;
    --dry-run)    MODE=dry-run ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
  shift
done

load_config "$INSTANCE"
build_vllm_args

if [[ "$MODE" == "dry-run" ]]; then
  print_plan
  exit 0
fi

check_port_free

PID_FILE="$(pid_file_path "$INSTANCE_NAME")"
LOG_FILE="$(log_file_path "$INSTANCE_NAME")"

if [[ "$MODE" == "background" && -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  die "实例 ${INSTANCE_NAME} 已在运行（PID $(cat "$PID_FILE")）"
fi

setup_ascend_env

if [[ "$MODE" == "background" ]]; then
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  nohup vllm "${VLLM_ARGS[@]}" >"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  log "实例 ${INSTANCE_NAME} 已后台启动：NPU ${NPU_ID}，端口 ${PORT}，PID $(cat "$PID_FILE")"
  log "日志：${LOG_FILE}"
  log "就绪检查：scripts/health_check.sh ${INSTANCE_NAME}"
else
  log "前台启动实例 ${INSTANCE_NAME}：NPU ${NPU_ID}，端口 ${PORT}（Ctrl+C 停止）"
  exec vllm "${VLLM_ARGS[@]}"
fi
