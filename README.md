# vLLM-Ascend 双实例部署工程化

把华为昇腾 A3（双 NPU）上 vLLM-Ascend 的手工部署流程，整理为**可配置、可校验、可测试**的脚本工程。

同一台机器上，两个实例分别绑定不同的 NPU、端口和加载方式，互不干扰：

| 实例 | NPU | 端口 | 权重加载 | 配置文件 |
|------|-----|------|---------|---------|
| a | `ASCEND_RT_VISIBLE_DEVICES=0` | 8000 | 在线（首次下载） | `configs/instances/a.env` |
| b | `ASCEND_RT_VISIBLE_DEVICES=1` | 8001 | 离线（复用缓存） | `configs/instances/b.env` |

模型为 `Qwen/Qwen3-4B`，投机解码使用 DSpark（草稿模型 `deepseek-ai/dspark_qwen3_4b_block7`）。

## A3 推理性能实验

在同一颗 Ascend910 上对 Qwen3-4B 完成普通解码与 DSpark 的 16 轮对照。并发上限为 1、4、8、16，DSpark 的输出吞吐提高 77.7%–90.3%，平均 TPOT 下降，p95 首 token 延迟升高。独立 Profiler 采样也记录到更少的 NPU kernel 执行。[实验报告、性能图和逐轮数据](docs/experiments/2026-11-23-dspark-a3/README.md)

## 目录结构

```
configs/
  common.env          # 共享配置：昇腾环境、模型、vLLM 参数
  instances/a.env     # 实例 A：NPU、端口、离线开关
  instances/b.env     # 实例 B
scripts/
  serve.sh            # 启动实例（前台 / 后台 / dry-run）
  stop.sh             # 停止后台实例
  health_check.sh     # 轮询 /v1/models 直到就绪
  lib/common.sh       # 配置加载、校验、参数组装、环境设置
tests/
  test_scripts.sh     # 无需 NPU 的脚本测试
docs/
  legacy-guide.md     # 原始手工部署指导书（脱敏副本，作为来源记录）
  experiments/        # 实验报告和性能数据
.github/workflows/ci.yml   # ShellCheck + 语法检查 + 测试
```

## 快速开始

以下命令在昇腾服务器上执行。

```bash
# 1. 先检查将要执行的命令，不需要 NPU 环境
scripts/serve.sh a --dry-run

# 2. 后台启动实例 A，日志写入 logs/a.log
scripts/serve.sh a --background

# 3. 等待服务就绪（模型加载可能需要数分钟）
scripts/health_check.sh a

# 4. 停止实例
scripts/stop.sh a
```

前台运行可直接执行 `scripts/serve.sh a`，用 Ctrl+C 停止。

## 设计要点

- **参数用数组组装**（`build_vllm_args`），不用反斜杠续行拼接命令。这样能避免续行符后出现空格或注释导致的命令截断（见下文"已修复的问题"）。
- **配置分层**：`common.env` 放共享项，实例文件只覆盖差异项（NPU、端口、离线开关）。新增实例只需新增一个 `.env` 文件。
- **启动前校验**：端口范围、NPU 编号、离线开关取值、显存比例等在启动前检查，错误尽早暴露。
- **端口占用检查**：启动前检测端口是否已被监听，避免新进程静默失败。
- **dry-run 可测试**：参数组装逻辑不依赖 NPU，可在普通机器上测试（CI 即如此运行）。
- **不在仓库中保存敏感信息**：IP、跳板机地址、token、密码均不入库。

## 测试与 CI

```bash
bash tests/test_scripts.sh      # 16 项测试：dry-run 输出、输入校验、非法配置拒绝
```

CI（GitHub Actions）在每次 push 和 PR 时执行：

1. ShellCheck 静态检查
2. `bash -n` 语法检查
3. `tests/test_scripts.sh`

## 已修复的问题

原指导书 `serve2.sh`（实例 B）的写法是：

```bash
--host 127.0.0.1 --port 8001 \  # 差异4：端口 8001
```

反斜杠后面有空格和注释，**不是合法的行尾续行**。bash 会在 `--port 8001` 处结束命令，之后的 `--served-model-name ...` 等参数会被当成独立命令执行，并报 `command not found`。本仓库用参数数组实现，已避免该问题。

## 尚未覆盖的范围

- 仓库中的双实例 Shell 部署入口尚未在真实 NPU 上重新验证。A3 性能实验使用同一设备顺序启动两个 vLLM 服务，启动参数见实验报告。
- **测试工具（aisbench）安装脚本未包含。** 原指导书的 `setup-test.sh` 会拉取第三方仓库并修改其配置，后续单独处理。

## 来源说明

脚本参数和流程来自作者在课程环境中的部署记录，已改写为可配置的形式。`docs/legacy-guide.md` 是原指导书的脱敏副本，IP 地址已替换为 `<JUMP_HOST>` 和 `<TARGET_HOST>`。原课件（PPT）不纳入仓库。
