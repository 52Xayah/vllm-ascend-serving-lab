# vLLM-Ascend 双人并行实操课前准备（SSH直连版 · 昇腾A3单卡）

> 适用场景：HiDevLab 昇腾 **A3 单卡（含 2 个 NPU）** 环境，两人通过 SSH 同时连接同一环境，各绑定 1 个 NPU 并行进行 vLLM 实操。
> 本文参考《鲲鹏昇腾开源技术高校行华南站 | vLLM实操活动课前准备》（基于 A2 环境 WebIDE 的课前指导书）改写为 SSH 双人版，**全程由学生自助完成，无需助教/教师代操作**。
>
> **分工约定**：两人共用一台环境（用其中一人的 HiDevLab 账号创建环境）。下文"用户A"指环境创建者（负责课前准备），"用户B"指同伴。
>
> **验证结论（已在真实 A3 环境实测通过）**：
> - ✅ 双 vLLM 实例并行：Chip 0（端口 8000）+ Chip 1（端口 8001）同时服务，互不干扰
> - ✅ 并发推理：两端口同时请求，同时返回 200 OK
> - ✅ 双人 SSH 同时在线：同一连接命令，两个并发会话
> - ✅ 权重缓存共享：课前下载一次（约 11G），两人复用，用户B零下载启动

---

## 一、方案原理（先看懂再动手）

| 隔离维度 | 用户A | 用户B |
|---------|-------|-------|
| NPU 绑定 | `ASCEND_RT_VISIBLE_DEVICES=0` | `ASCEND_RT_VISIBLE_DEVICES=1` |
| 服务端口 | 8000 | 8001 |
| 服务目录 | `/workspace/dspark-lab` | `/workspace/dspark-lab-2` |
| 测试工具 | `/workspace/test` | `/workspace/test-b-tools` |
| 权重缓存 | 共享 `/workspace/qwen-dspark-online/hf-cache`（只读复用） | 同左（离线模式） |

A3 单卡通过 `npu-smi info` 可看到 2 颗 Ascend910 芯片（Chip 0 / Chip 1，各 64G HBM）。两人各自把 vLLM 进程"钉"在不同的 NPU 上，即实现一台环境两人实操。

> 原指导书中的"会话一（启服务）/会话二（装工具）"双人版对应关系：**用户A 的终端1/终端2 走原流程；用户B 走本文第 5 章的并行流程。**

---

## 二、SSH 连接必读（重要坑位）

### 2.1 获取连接信息

环境开机后，在 HiDevLab【开发环境】列表点【连接】→【SSH直连】，弹窗提供：

```
连接命令：ssh -J jt_xxx:yyy@<JUMP_HOST>:2234 root@<TARGET_HOST>
连接密码：********（5分钟失效）
```

**注意：**
- 跳板 token（`jt_...` 部分）**约 5 分钟时效、且连接次数有限**，过期后再次点击【SSH直连】即可重新获取（环境可反复获取，密码不变）。
- **同一份连接命令可以给两人同时使用**（已实测两个并发连接成功）。
- 因此正确姿势：**连接前现取 token，取到后 5 分钟内完成首次连接**；两人都用这份命令各自连接。

### 2.2 首次连接（各操作系统通用）

本地打开终端（Windows 用 CMD/PowerShell，Mac/Linux 用 Terminal），粘贴连接命令，输入密码：

```bash
ssh -J jt_xxx:yyy@<JUMP_HOST>:2234 root@<TARGET_HOST>
# 首次连接询问 yes/no 时输入 yes
# 提示 password 时输入连接密码
```

看到 `root@xxx:/workspace#` 提示符即成功。

### 2.3 连接保活与复用（强烈建议，规避 token 时效）

跳板 token 时效短，断线后旧 token 可能失效。用 SSH 连接复用（ControlMaster）可以**一次连接、长期多终端复用**，不再依赖 token：

**Mac/Linux** 用户在 `~/.ssh/config`（没有则新建）中加入：

```
Host hidevlab-a3
    HostName <TARGET_HOST>
    User root
    ProxyJump jt_xxx:yyy@<JUMP_HOST>:2234
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 4h
```

之后连接只需 `ssh hidevlab-a3`；新开终端、断网重连都自动复用主连接（4 小时内不再需要 token）。

**Windows** 用户可跳过此配置，但注意：断线后如果 token 已过期，需重新到平台点击【SSH直连】获取新连接命令。

### 2.4 断线重连

```bash
# 重新点击【连接】→【SSH直连】获取新命令（若旧 token 失效）
# 用新命令重连；环境内数据和后台进程不受断线影响
```

---

## 三、课前准备（用户A自行完成，建议课前 1 天）

> 目标：提前下载主模型、DSpark 草稿权重和全部测试工具，并搭好**用户B的并行目录**。课堂两人直接复用，全程零下载。
> 请在上课使用的同一环境完成；更换环境后需重新准备。
> 耗时约 20 分钟（其中权重下载约 10 分钟）。

### 步骤 1 连接环境并确认双 NPU

SSH 连入后执行：

```bash
npu-smi info
```

应看到 2 颗 Ascend910（Chip 0 和 Chip 1，各 65536 MB HBM）。确认 NPU 均空闲（`No running processes found`）。

### 步骤 2 准备用户A服务启动脚本（与原指导书一致）

创建目录并打开文件：

```bash
mkdir -p /workspace/dspark-lab
cd /workspace/dspark-lab
vi serve.sh
```

按 `i` 进入编辑模式（注意输入法不要是中文），粘贴下面完整脚本，按 `Esc`，输入 `:wq` 回车保存：

```bash
#!/usr/bin/env bash
set -e
cd /workspace/dspark-lab
export PATH=/usr/local/python3.12.13/bin:$PATH
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh --cxx_abi=1
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${LD_LIBRARY_PATH:-}
export ASCEND_RT_VISIBLE_DEVICES=0
export OMP_NUM_THREADS=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_TIMEOUT=120
export HF_HOME=/workspace/qwen-dspark-online/hf-cache
unset HF_HUB_OFFLINE TRANSFORMERS_OFFLINE
exec vllm serve Qwen/Qwen3-4B \
  --host 127.0.0.1 --port 8000 --served-model-name qwen-dspark \
  --tensor-parallel-size 1 --dtype bfloat16 \
  --max-model-len 8192 --max-num-seqs 16 --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.8 --enforce-eager --no-async-scheduling --seed 42 \
  --no-enable-prefix-caching \
  --speculative-config '{"method":"dspark","model":"deepseek-ai/dspark_qwen3_4b_block7","num_speculative_tokens":7,"enforce_eager":true}'
```

### 步骤 3 首次拉起服务并下载全部权重

```bash
cd /workspace/dspark-lab
bash serve.sh
```

第一次启动会下载模型文件，约 10 分钟。看到 `Application startup complete` 即成功。此时**保留服务运行**，另开一个终端（或临时挂起 `Ctrl+Z`）继续步骤 4。

权重缓存位于 `/workspace/qwen-dspark-online/hf-cache`（约 11G，含主模型 + DSpark 草稿模型）。

### 步骤 4 准备用户B服务脚本（关键差异：NPU 1 + 端口 8001 + 离线缓存）

另开终端连接（同一个连接命令）：

```bash
mkdir -p /workspace/dspark-lab-2
cd /workspace/dspark-lab-2
vi serve2.sh
```

粘贴下面完整脚本（与前者的差异仅 4 处，已用注释标出）：

```bash
#!/usr/bin/env bash
set -e
cd /workspace/dspark-lab-2                      # 差异1：用户B独立目录
export PATH=/usr/local/python3.12.13/bin:$PATH
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh --cxx_abi=1
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${LD_LIBRARY_PATH:-}
export ASCEND_RT_VISIBLE_DEVICES=1              # 差异2：绑定 NPU 1
export OMP_NUM_THREADS=1
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
export HF_ENDPOINT=https://hf-mirror.com
export HF_HUB_DISABLE_XET=1
export HF_HUB_DOWNLOAD_TIMEOUT=120
export HF_HOME=/workspace/qwen-dspark-online/hf-cache
export HF_HUB_OFFLINE=1                         # 差异3：离线模式，直接复用已下载权重
export TRANSFORMERS_OFFLINE=1
exec vllm serve Qwen/Qwen3-4B \
  --host 127.0.0.1 --port 8001 \                # 差异4：端口 8001
  --served-model-name qwen-dspark \
  --tensor-parallel-size 1 --dtype bfloat16 \
  --max-model-len 8192 --max-num-seqs 16 --max-num-batched-tokens 8192 \
  --gpu-memory-utilization 0.8 --enforce-eager --no-async-scheduling --seed 42 \
  --no-enable-prefix-caching \
  --speculative-config '{"method":"dspark","model":"deepseek-ai/dspark_qwen3_4b_block7","num_speculative_tokens":7,"enforce_eager":true}'
```

### 步骤 5 验证双实例并行（课前自检）

在第二个终端启动用户B服务：

```bash
cd /workspace/dspark-lab-2
bash serve2.sh
```

两个终端分别看到 `Application startup complete` 后，另开终端验证：

```bash
# 两个服务同时应答
curl -fsS http://127.0.0.1:8000/v1/models
curl -fsS http://127.0.0.1:8001/v1/models

# 两颗 NPU 各跑一个 vLLM 进程
npu-smi info
# 预期看到：Chip 0 和 Chip 1 各有一个 VLLMEngineCor 进程，HBM 各占约 52G
```

### 步骤 6 安装测试工具（与原指导书一致）

在第二个终端（保持服务运行）执行：

```bash
mkdir -p /workspace/test
cd /workspace/test
vi setup-test.sh
```

粘贴下面完整 `setup-test.sh` 脚本，保存后执行：

```bash
#!/usr/bin/env bash
set -eo pipefail
ROOT=/workspace/test
export PATH=/usr/local/python3.12.13/bin:$PATH
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh --cxx_abi=1
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${LD_LIBRARY_PATH:-}
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
mkdir -p "$ROOT"/{tmp,pip-cache,datasets,outputs}
export PIP_CACHE_DIR="$ROOT/pip-cache" TMPDIR="$ROOT/tmp"
export PIP_INDEX_URL=https://repo.huaweicloud.com/repository/pypi/simple
export HF_ENDPOINT=https://hf-mirror.com HF_HOME="$ROOT/hf-cache"
cd "$ROOT"
if [ ! -d aisbench_auto_tools_prefix-master-pro ]; then
  git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/LookAround0301/aisbench_auto_tools_prefix-master-pro.git
fi
if [ ! -d benchmark ]; then
  git -c http.version=HTTP/1.1 clone --depth 1 https://github.com/AISBench/benchmark.git
fi
if [ ! -d venv ]; then python -m venv --system-site-packages "$ROOT/venv"; fi
source "$ROOT/venv/bin/activate"
python -m pip install -e "$ROOT/benchmark" --use-pep517
python -m pip install -r "$ROOT/benchmark/requirements/api.txt"
python - <<'PY'
from pathlib import Path
import re
from huggingface_hub import snapshot_download
root = Path('/workspace/test')
snapshot_download('Qwen/Qwen3-4B', local_dir=str(root / 'tokenizer'),
    allow_patterns=['config.json', 'tokenizer.json', 'tokenizer_config.json',
                    'special_tokens_map.json', 'vocab.json', 'merges.txt', 'chat_template.jinja'])
p = root / 'aisbench_auto_tools_prefix-master-pro/config.py'
s = p.read_text()
values = dict(DATASET_PATH=str(root/'datasets'), WORK_PATH=str(root/'benchmark'),
              MODEL_NAME='qwen-dspark', MODEL_PATH=str(root/'tokenizer'),
              HOST_IP='127.0.0.1', HOST_PORT='8000', DEFAULT_PERFORMANCE_TEST='default_perf')
for key, value in values.items():
    s, count = re.subn(r'^'+key+r'\s*=.*$', key+' = '+repr(value), s, flags=re.M)
    if count != 1: raise RuntimeError(f'config.py字段不匹配：{key}')
p.write_text(s)
p = root / 'aisbench_auto_tools_prefix-master-pro/aisbench_result.csv'
if p.exists() and p.stat().st_size == 0: p.unlink()
PY
python - <<'PY'
from pathlib import Path
p = Path('/workspace/test/venv/bin/activate')
s = p.read_text()
marker = '# DSPARK_LAB_TEST_ENV'
if marker in s: s = s.split(marker, 1)[0]
s += '''
# DSPARK_LAB_TEST_ENV
source /usr/local/Ascend/ascend-toolkit/set_env.sh
source /usr/local/Ascend/nnal/atb/set_env.sh --cxx_abi=1
export LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${LD_LIBRARY_PATH:-}
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
export HF_ENDPOINT=https://hf-mirror.com
export HF_HOME=/workspace/test/hf-cache
export PIP_CACHE_DIR=/workspace/test/pip-cache
export TMPDIR=/workspace/test/tmp
'''
p.write_text(s)
PY
source "$ROOT/venv/bin/activate"
ais_bench --help >/dev/null
cd "$ROOT/aisbench_auto_tools_prefix-master-pro"
printf '\n测试环境已就绪。当前目录：%s\n' "$PWD"
```

> 提示：脚本必须用 `source /workspace/test/setup-test.sh` 执行（不要用 `bash`），否则环境变量不会写进当前会话。

等待出现「测试环境已就绪」。它自动下载 aisbench 工具仓库、安装独立测试虚拟环境、准备分词器并完成配置。

### 步骤 7 创建用户B测试工具副本（指向端口 8001）

```bash
cp -r /workspace/test/aisbench_auto_tools_prefix-master-pro /workspace/test-b-tools
sed -i "s/HOST_PORT = '8000'/HOST_PORT = '8001'/" /workspace/test-b-tools/config.py
grep HOST_PORT /workspace/test-b-tools/config.py   # 确认输出 HOST_PORT = '8001'
```

### 步骤 8 停止服务，保留缓存

确认全部就绪后，在两个服务终端分别按 `Ctrl+C` 停止（或执行 `pkill -f 'vllm serve'`），等待回到 shell 提示符。

**保留以下目录，课堂直接复用：**
- `/workspace/dspark-lab`、`/workspace/dspark-lab-2`（双服务脚本）
- `/workspace/qwen-dspark-online/hf-cache`（共享权重，用户B离线复用）
- `/workspace/test`、`/workspace/test-b-tools`（双人测试工具）

### 课前准备检查清单

| 检查项 | 命令 | 预期 |
|--------|------|------|
| 双NPU就绪 | `npu-smi info` | 2× Ascend910，无进程 |
| 服务脚本 | `ls /workspace/dspark-lab/serve.sh /workspace/dspark-lab-2/serve2.sh` | 两个文件存在 |
| 权重缓存 | `du -sh /workspace/qwen-dspark-online/hf-cache` | 约 11G |
| 测试工具 | `ls /workspace/test/setup-test.sh /workspace/test-b-tools/config.py` | 存在，B 的 HOST_PORT='8001' |
| 环境状态 | HiDevLab 环境列表 | 开机/待机（勿删除环境） |

---

## 四、连接环境（双人）

1. 用户A（环境创建者）在 HiDevLab 点击【连接】→【SSH直连】，**当场**获取新连接命令，发给用户B（两人都在 5 分钟内完成首次连接）。
2. 两人各自在自己的电脑终端执行连接命令 + 密码（参考 2.2 节）。
3. 连接后各自自检：

```bash
npu-smi info     # 应看到 2 颗 NPU
ls /workspace/dspark-lab/serve.sh /workspace/dspark-lab-2/serve2.sh   # 课前脚本就位
```

> 建议两人都按 2.3 节配置 ControlMaster，之后新开终端、断线重连都不再消耗 token。

---

## 五、双人并行实操

### 用户A（NPU 0 / 端口 8000）

终端1 —— 启动服务：

```bash
cd /workspace/dspark-lab
bash serve.sh
# 等待 Application startup complete（权重已缓存，约 1-2 分钟）
```

终端2 —— 验证并运行测试：

```bash
curl -fsS http://127.0.0.1:8000/v1/models     # 确认服务就绪
source /workspace/test/setup-test.sh           # 激活测试环境
# 按课程讲义执行：
# python aisbench_test.py
```

### 用户B（NPU 1 / 端口 8001）

终端1 —— 启动服务：

```bash
cd /workspace/dspark-lab-2
bash serve2.sh
# 等待 Application startup complete（离线加载，无需下载）
```

终端2 —— 验证并运行测试：

```bash
curl -fsS http://127.0.0.1:8001/v1/models     # 确认服务就绪（注意端口是 8001）
source /workspace/test/venv/bin/activate       # 激活同一测试环境（共享只读）
cd /workspace/test-b-tools                     # 进入用户B专用工具目录（已指向8001）
# 按课程讲义执行：
# python aisbench_test.py
```

### 双人并行确认

任一终端执行：

```bash
npu-smi info
# 预期：Chip 0 上用户A的 VLLMEngineCor + Chip 1 上用户B的 VLLMEngineCor 同时运行
```

两人在各自终端互不影响地完成服务拉起、推理验证、性能测试全流程。

---

## 六、注意事项与 FAQ

**Q1：连不上 / 提示 `administratively prohibited: platform authorization denied`？**
跳板 token 已过期。重新到 HiDevLab 点击【SSH直连】获取新命令，重新连接即可（密码不变，环境内进度不受影响）。

**Q2：为什么用户B不用重新下载模型？**
权重缓存在课前已下载完成且共享，用户B的 `serve2.sh` 设置了 `HF_HUB_OFFLINE=1` 离线模式，直接从缓存加载，同时避免两人并发访问网络仓库的冲突。

**Q3：两人会不会互相干扰？**
不会。NPU 通过 `ASCEND_RT_VISIBLE_DEVICES` 硬隔离（各占一颗芯片），端口 8000/8001 独立，工作目录独立。唯一共享的是权重缓存（只读）和测试虚拟环境（只读激活），已实测并行无冲突。

**Q4：可以一人 WebIDE 一人 SSH 吗？**
可以。WebIDE 走平台自带通道（点【连接】→【WebIDE】，不占 SSH token），用户A按原 WebIDE 指导书操作、用户B按本文 SSH 流程操作即可，容器内目录完全相同。

**Q5：环境会自动关机吗？**
连续 1 小时未操作会自动关机（关机即停扣卡时）。课堂中保持 SSH 连接与操作即可；关机后 `/workspace` 内数据保留，重新开机即可继续。**注意勿删除环境，删除将清空全部数据。**

**Q6：服务启动后想停止？**
在服务所在终端按 `Ctrl+C`，等待回到 shell 提示符；或另开终端执行 `pkill -f 'vllm serve'`。

**Q7：想确认端口是否被占用？**
```bash
netstat -tlnp | grep -E ':(8000|8001)'
```
无输出即空闲。

---

## 附：与原 A2 WebIDE 指导书的差异速查

| 项目 | 原版（A2 · WebIDE） | 本文（A3 · SSH双人） |
|------|--------------------|--------------------|
| 算力 | A2 单 NPU | A3 单卡双 NPU |
| 接入 | WebIDE 内建终端 | 本地终端 SSH 直连（跳板 token 约 5 分钟时效） |
| 使用人数 | 1 人（会话一/二分工） | 2 人并行（NPU/端口/目录三维隔离） |
| 权重下载 | 每环境一次 | 课前一次，双人共享（B 离线复用） |
| 测试工具 | `/workspace/test` 一套 | `/workspace/test` + `/workspace/test-b-tools`（8001） |
| 脚本 | `serve.sh` | `serve.sh` + `serve2.sh`（4 处差异见步骤 4） |
