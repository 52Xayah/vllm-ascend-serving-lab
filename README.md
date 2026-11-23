# vLLM-Ascend Serving Lab

在华为昇腾 A3 上部署和测量 Qwen3-4B 推理服务。项目把课程中的双实例部署整理成可配置的 Shell 脚本，并用单 NPU 对照实验回答一个问题：**DSpark 如何改变解码吞吐、首 token 延迟和设备开销？**

## 实测结果

在同一颗 Ascend910 上固定主模型、推理参数和请求长度，依次运行普通解码与 DSpark block7。实验共 **16 轮、384 个请求、49,152 个输出 token**，覆盖并发上限 1、4、8、16。DSpark 在四个并发点的吞吐增幅为 **77.7%–90.3%**。

| 并发上限 | 输出吞吐（token/s） | 平均 TPOT（ms） | p95 TTFT（ms） |
| ---: | ---: | ---: | ---: |
| 1 | 24.27 → 44.68 | 41.14 → 22.68 | 51.99 → 63.53 |
| 4 | 88.89 → 157.99 | 44.51 → 21.95 | 119.30 → 142.18 |
| 8 | 172.48 → 328.23 | 45.39 → 19.60 | 191.71 → 215.50 |
| 16 | 255.46 → 482.26 | 45.65 → 20.81 | 346.74 → 394.47 |

箭头从普通解码指向 DSpark。每项取两轮实测指标的中位数。TPOT 是首 token 之后的平均单 token 耗时，TTFT 是首 token 延迟。

![普通解码与 DSpark 在并发 1、4、8、16 下的吞吐与延迟](docs/experiments/2026-11-23-dspark-a3/performance.png)

- **解码轮次。** block7 每轮最多提议 7 个草稿 token。实测平均接受长度为 **2.60–2.97 token/轮**，包含目标模型输出的一个 token。一次验证可推进多个 token，减少逐 token 串行解码的轮次。
- **NPU 时间线。** 对同一条 32 输出 token 的贪心请求，两个服务输出文本一致。独立采样中，`FusedInferAttentionScore` 从 **1,152 次降到 574 次**，NPU kernel 记录从 **14,738 降到 10,632**。时间线没有独立标注草稿生成和目标验证，暂时无法拆分两段耗时。
- **代价。** 四个并发点的 p95 TTFT 均升高，启动日志记录的可用 KV Cache 内存从 **41.13 GiB 降到 38.38 GiB**。测试使用固定长度的合成请求，每个点只有两轮，适用范围限于本次硬件、模型和负载。

[实验设计、完整结果与复现命令](docs/experiments/2026-11-23-dspark-a3/README.md) · [16 轮数据 CSV](docs/experiments/2026-11-23-dspark-a3/trials-rounded.csv) · [Profiler 指标 CSV](docs/experiments/2026-11-23-dspark-a3/profile-summary.csv)

## 双实例部署

[原课程流程](docs/legacy-guide.md)记录了 A3 上两个实例并行推理和共享权重缓存的手工验证。仓库将公共参数和实例参数分开，使用 Bash 数组组装 vLLM 命令，修复了手工脚本里反斜杠后跟注释导致的命令截断。启动脚本支持 dry-run、端口检查及前后台运行，后台实例配有就绪检查、日志和停止入口。

| 部署实例 | 可见设备 | 端口 | 权重加载 |
| --- | --- | ---: | --- |
| [a](configs/instances/a.env) | `ASCEND_RT_VISIBLE_DEVICES=0` | 8000 | 在线，首次下载主模型与草稿权重 |
| [b](configs/instances/b.env) | `ASCEND_RT_VISIBLE_DEVICES=1` | 8001 | 离线，复用 a 已准备好的 `HF_HOME` |

部署实例 a 和 b 当前都启用 DSpark。单 NPU 性能实验直接用 vLLM CLI 顺序启动两种解码模式，具体参数见实验报告。

### 快速开始

需要有 Ascend NPU 的 Linux 环境、与镜像匹配的 CANN、ATB 和 vLLM-Ascend，以及 Bash 和 curl。先运行 `npu-smi info` 确认设备编号，再按实际镜像核对 [公共配置](configs/common.env)中的环境脚本、Python 路径及模型缓存目录。使用 b 前，确认同一缓存中已有主模型和 DSpark 草稿权重。

```bash
bash scripts/serve.sh a --dry-run
bash scripts/serve.sh a --background
bash scripts/health_check.sh a
bash scripts/stop.sh a
```

后台日志位于 `logs/a.log`，PID 记录位于 `run/a.pid`。前台运行可执行 `bash scripts/serve.sh a`，用 Ctrl+C 停止。

## 复现与数据

| 位置 | 内容 |
| --- | --- |
| [configs/](configs/) | 共享环境、模型参数与两个部署实例 |
| [scripts/](scripts/) | 启动、就绪检查、停止与公共函数 |
| [tests/](tests/) | 16 项 dry-run、参数组装和配置校验测试 |
| [docs/experiments/](docs/experiments/) | A3 实验报告、复现命令、性能图和指标 CSV |

完整原始归档名为 `dspark-a3-results-20261123.tar.gz`，本地项目保留一份。归档含 311 个文件，包括 16 轮原始压测 JSON、32 份 Prometheus 快照、4 组服务日志和预热数据、2 份完整 Profiler 时间线、权重哈希、环境信息和实际执行脚本。GitHub 收录实验报告、图和数据摘录。归档 SHA-256 为：

```text
45540b1b10b817886b71651d1ccfa08237b289e5feec5b23d0f766e3cbe27daa
```

## 验证范围

- **Shell 脚本。** [CI](.github/workflows/ci.yml)配置了 ShellCheck、Bash 语法检查和 `bash tests/test_scripts.sh`。当前测试覆盖 dry-run 与配置校验。双实例脚本的后台启停、就绪检查，以及两实例并行与离线缓存复用，仍需用仓库入口在真实设备上端到端回归。
- **A3 性能。** 已完成单设备对照及独立 Profiler 采样。报告提供可手动执行的复现命令，实际批量运行和汇总脚本随原始归档保存。
