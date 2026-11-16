#!/usr/bin/env bash
# 公共函数：配置加载与校验、vLLM 参数组装、昇腾环境设置。
# 由其他脚本 source 使用，不直接执行。
# 注意：不启用 set -u，因为昇腾 set_env.sh 可能引用未定义变量。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_DIR="${CONFIG_DIR:-${REPO_ROOT}/configs}"
RUN_DIR="${RUN_DIR:-${REPO_ROOT}/run}"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/logs}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[%s] 错误：%s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

list_instances() {
  local f names=()
  for f in "${CONFIG_DIR}"/instances/*.env; do
    [[ -e "$f" ]] || continue
    names+=("$(basename "$f" .env)")
  done
  local IFS=,
  echo "${names[*]}"
}

# 加载配置：先共享配置，再实例配置（实例值覆盖共享值）
load_config() {
  local instance="$1"
  [[ -n "$instance" ]] || die "未指定实例名（可用实例：$(list_instances)）"
  local instance_file="${CONFIG_DIR}/instances/${instance}.env"
  [[ -f "$instance_file" ]] || die "实例配置不存在：${instance_file}（可用实例：$(list_instances)）"
  # shellcheck source=/dev/null
  source "${CONFIG_DIR}/common.env"
  # shellcheck source=/dev/null
  source "$instance_file"
  validate_config
}

validate_config() {
  local var
  for var in INSTANCE_NAME MODEL SERVED_MODEL_NAME HOST PORT NPU_ID HF_OFFLINE \
             TENSOR_PARALLEL_SIZE DTYPE MAX_MODEL_LEN MAX_NUM_SEQS \
             MAX_NUM_BATCHED_TOKENS GPU_MEMORY_UTILIZATION SEED SPECULATIVE_CONFIG; do
    [[ -n "${!var:-}" ]] || die "配置项 ${var} 为空"
  done
  is_uint "$PORT" || die "PORT 必须为整数：$PORT"
  (( PORT >= 1024 && PORT <= 65535 )) || die "PORT 超出范围 1024-65535：$PORT"
  is_uint "$NPU_ID" || die "NPU_ID 必须为非负整数：$NPU_ID"
  is_uint "$TENSOR_PARALLEL_SIZE" || die "TENSOR_PARALLEL_SIZE 必须为整数：$TENSOR_PARALLEL_SIZE"
  [[ "$HF_OFFLINE" == "0" || "$HF_OFFLINE" == "1" ]] || die "HF_OFFLINE 只能为 0 或 1：$HF_OFFLINE"
  [[ "$GPU_MEMORY_UTILIZATION" =~ ^(0?\.[0-9]+|1(\.0+)?)$ ]] \
    || die "GPU_MEMORY_UTILIZATION 必须在 (0, 1] 之间：$GPU_MEMORY_UTILIZATION"
}

# 组装 vllm serve 参数数组（使用数组代替反斜杠续行，避免续行符后出现空格或注释导致命令被截断）
build_vllm_args() {
  VLLM_ARGS=(serve "$MODEL"
    --host "$HOST" --port "$PORT"
    --served-model-name "$SERVED_MODEL_NAME"
    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE"
    --dtype "$DTYPE"
    --max-model-len "$MAX_MODEL_LEN"
    --max-num-seqs "$MAX_NUM_SEQS"
    --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
    --seed "$SEED"
    --speculative-config "$SPECULATIVE_CONFIG")
  local extra=()
  read -r -a extra <<< "${VLLM_EXTRA_ARGS:-}"
  VLLM_ARGS+=("${extra[@]}")
}

# dry-run：只打印将要生效的关键环境变量与命令，不需要昇腾环境
print_plan() {
  printf 'INSTANCE=%s\n' "$INSTANCE_NAME"
  printf 'ASCEND_RT_VISIBLE_DEVICES=%s\n' "$NPU_ID"
  printf 'PORT=%s\n' "$PORT"
  if [[ "$HF_OFFLINE" == "1" ]]; then
    printf 'HF_HUB_OFFLINE=1\n'
  else
    printf 'HF_HUB_OFFLINE=(unset)\n'
  fi
  printf 'HF_HOME=%s\n' "$HF_HOME"
  printf 'COMMAND: vllm'
  printf ' %q' "${VLLM_ARGS[@]}"
  printf '\n'
}

# 真实启动前设置昇腾与 HuggingFace 环境（与原指导书脚本保持一致）
setup_ascend_env() {
  [[ -f "$ASCEND_TOOLKIT_ENV" ]] || die "找不到 CANN toolkit 环境脚本：$ASCEND_TOOLKIT_ENV"
  [[ -f "$ASCEND_ATB_ENV" ]] || die "找不到 ATB 环境脚本：$ASCEND_ATB_ENV"
  export PATH="${PYTHON_BIN_DIR}:${PATH}"
  # shellcheck source=/dev/null
  source "$ASCEND_TOOLKIT_ENV"
  # shellcheck source=/dev/null
  source "$ASCEND_ATB_ENV" --cxx_abi=1
  export LD_LIBRARY_PATH="${ASCEND_DRIVER_LIB_DIR}/common:${ASCEND_DRIVER_LIB_DIR}/driver:${LD_LIBRARY_PATH:-}"
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
  export ASCEND_RT_VISIBLE_DEVICES="$NPU_ID"
  export OMP_NUM_THREADS PYTORCH_NPU_ALLOC_CONF
  export HF_ENDPOINT HF_HOME
  export HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_TIMEOUT=120
  if [[ "$HF_OFFLINE" == "1" ]]; then
    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
  else
    unset HF_HUB_OFFLINE TRANSFORMERS_OFFLINE
  fi
}

# 检查端口是否已被监听（bash 内置 /dev/tcp，无需 netstat）
check_port_free() {
  if (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null; then
    die "端口 ${PORT} 已被占用，请先检查：scripts/stop.sh ${INSTANCE_NAME} 或 netstat -tlnp | grep ${PORT}"
  fi
}

pid_file_path() { echo "${RUN_DIR}/${1}.pid"; }
log_file_path() { echo "${LOG_DIR}/${1}.log"; }
