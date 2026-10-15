# 构建最新 vLLM / vLLM-Ascend

```bash
git pull --ff-only
bash vllm_build_latest.sh
```

在已配置 CANN、代理、torch 和 torch_npu 的 Ascend 容器中运行。
只安装这两个项目，不安装或更新 afd-plugin；原有固定 0.30.0 的
`afd_build_and_compile.sh` 不变。

## 执行内容

1. 检查 Python 3.11+、SSL、NPU/CANN，记录当前 torch 配套版本。
2. clone 或 fetch 两个官方仓库的最新 `main`，以 detached HEAD 固定本次实际 commit。
3. 准备 submodule，包括 Ascend 所需的 catlass。
4. 使用官方 `use_existing_torch.py`，按 `VLLM_TARGET_DEVICE=empty` 安装 vLLM。
   同时兼容 helper 在根目录或 `tools/` 下的布局，结束时恢复它生成的依赖文件改动。
5. 按 `SOC_VERSION` 编译安装 vLLM-Ascend，包括 custom kernels。
6. 最后才完整导入两个包，检查加载位置、Ascend 平台和 `pip check`。

每次执行都进行安装，**不使用 stamp，不需要 `--force`**；底层编译工具仍可能复用缓存。
不会删除仓库、清空本地改动或执行强制 reset。已有源码有修改时停止，请先自行备份或提交。

默认源码目录：`/home/s00988495/AFD-latest`。
源码与固定版本目录分离，**但 editable 安装仍会替换当前 Python 环境中的包**。
测试新栈建议使用专用容器；不会自动迁移已有 AFD 插件。

日志、实际 commit 和 torch 约束记录保存在 `AFD-latest/logs/`，按执行时间独立命名。
任何步骤失败都会停止并打印日志位置；若最终 `pip check` 发现旧环境中的其他包冲突，
也会返回失败，不能将它视为完整可用的运行环境。脚本不启动模型，也不做推理测试。

## 可选设置

```bash
# 自定义源码目录和编译并行度
BUILD_ROOT=/home/s00988495/AFD-latest MAX_JOBS=16 bash vllm_build_latest.sh

# 无法自动识别芯片时，以实际硬件型号为准
SOC_VERSION=ascend950pr_9589 bash vllm_build_latest.sh

# 仅 OpenSSL 冲突机器需要；普通机器不设置该变量
OPENSSL35_PATH=/home/miniconda3/pkgs/openssl-3.5.7-h39c9139_0/lib \
  bash vllm_build_latest.sh
```

OpenSSL 选项让 Python 使用指定库、让通过 PATH 调用的 Git（包括构建子进程）使用系统库，
不修改全局配置。默认系统 Git 是 `/usr/bin/git`，必要时通过 `SYSTEM_GIT_BIN` 覆盖。
`PYTHON` 可指定 Python 解释器；`VLLM_URL` / `VLLM_ASCEND_URL` 可指定镜像仓库，仍取 `main`。

## 最新不等于已验证兼容

严格按本次要求取两个最新 `main`，不会自动换回旧 tag/commit，也不伪造版本号。
Ascend 如提供 `.github/vllm-main-verified.commit`，脚本会打印其已验证版本供比较，
但不会自动采用它。如果上游 API 或框架要求不兼容，仍需选择匹配版本或更换基础镜像。

所有 pip 安装都约束当前已安装的 torch、torch-npu、torchvision、torchaudio 版本，
不会静默切换到 PyPI 的其他框架版本；与上游要求冲突会明确失败。

构建方式参考上游 [已有 PyTorch 安装的源码构建](https://docs.vllm.ai/en/latest/getting_started/installation/gpu/#use-an-existing-pytorch-installation)
和 [Ascend 安装说明](https://docs.vllm.ai/projects/ascend/en/latest/getting_started/installation.html)。
