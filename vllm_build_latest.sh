#!/usr/bin/env bash
set -Eeuo pipefail

# 拉取两个上游 main 的最新代码，依次安装 vLLM empty、vLLM-Ascend。
# 用法：bash vllm_build_latest.sh
# 前提：容器内已配置 CANN、网络/代理，以及可用的 torch / torch_npu。
# 默认源码目录独立于固定版本脚本，但仍会替换当前 Python 环境中的包！
# 每次都执行安装，不使用 build stamp，不删除目录，不需要 --force。
# 不安装 afd-plugin；上游最新 main 不保证互相兼容，更不保证兼容旧 AFD。
# 可选：BUILD_ROOT、PYTHON、SOC_VERSION、MAX_JOBS。
# OpenSSL 冲突机器可显式指定 OPENSSL35_PATH；普通机器不需要设置。

if [[ $# -gt 0 ]]; then
    if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
        sed -n '4,12p' "$0"
        exit 0
    fi
    echo "用法：bash $0（无须 --force；每次都会安装）" >&2
    exit 2
fi

BUILD_ROOT="${BUILD_ROOT:-/home/s00988495/AFD-latest}"
PYTHON="${PYTHON:-python3}"
VLLM_URL="${VLLM_URL:-https://github.com/vllm-project/vllm.git}"
VLLM_ASCEND_URL="${VLLM_ASCEND_URL:-https://github.com/vllm-project/vllm-ascend.git}"
mkdir -p "$BUILD_ROOT/logs"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"
RUN_ID="$(date +%Y%m%d_%H%M%S)_$$"
LOG_FILE="$BUILD_ROOT/logs/build_latest_${RUN_ID}.log"
CONSTRAINTS="$BUILD_ROOT/logs/torch_${RUN_ID}.constraints.txt"
HELPER_PATCH="$BUILD_ROOT/logs/torch_helper_${RUN_ID}.patch"
VLLM_DIR="$BUILD_ROOT/vllm"
ASCEND_DIR="$BUILD_ROOT/vllm-ascend"
GIT_WRAPPER_DIR=""
STAGE=initialization
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup()
{
    local status=$?
    trap - EXIT
    # 只反向应用本次官方 helper 生成的 requirements/pyproject 改动。
    # 不 reset/clean 源码；若有并发改动导致无法恢复，则保留 patch 供人工处理。
    if [[ -s "$HELPER_PATCH" ]]; then
        if git -C "$VLLM_DIR" apply --reverse "$HELPER_PATCH"; then
            : > "$HELPER_PATCH"
        else
            echo "[ERROR] 无法恢复 helper 改动，保留 patch：$HELPER_PATCH"
            status=1
        fi
    fi
    if [[ -n "$GIT_WRAPPER_DIR" ]]; then
        rm -f -- "$GIT_WRAPPER_DIR/git" || true
        rmdir -- "$GIT_WRAPPER_DIR" || true
    fi
    [[ "$status" -eq 0 ]] || echo "[ERROR] 阶段=$STAGE；完整日志：$LOG_FILE"
    exit "$status"
}
trap cleanup EXIT

for tool in git "$PYTHON"; do
    command -v "$tool" >/dev/null || { echo "[ERROR] 未找到 $tool"; exit 1; }
done

# 可选隔离：临时 Git 入口覆盖 pip / CMake / Bash 子进程；不改全局配置。
if [[ -n "${OPENSSL35_PATH:-}" ]]; then
    [[ -d "$OPENSSL35_PATH" ]] || { echo "[ERROR] OpenSSL 目录不存在：$OPENSSL35_PATH"; exit 1; }
    export AFD_REAL_GIT="${SYSTEM_GIT_BIN:-/usr/bin/git}"
    [[ "$AFD_REAL_GIT" == /* && -x "$AFD_REAL_GIT" ]] || { echo '[ERROR] 系统 Git 路径无效'; exit 1; }
    GIT_WRAPPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/vllm-latest-git.XXXXXXXX")"
    cat > "$GIT_WRAPPER_DIR/git" <<'SH'
#!/bin/bash
set -euo pipefail
unset LD_LIBRARY_PATH LD_PRELOAD
exec "$AFD_REAL_GIT" "$@"
SH
    chmod 700 "$GIT_WRAPPER_DIR/git"
    export PATH="$GIT_WRAPPER_DIR:$PATH"
    export LD_LIBRARY_PATH="${OPENSSL35_PATH%/}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    hash -r
    echo "[env] OpenSSL 隔离启用：$OPENSSL35_PATH"
fi

# 不让旧 AFD/general plugins 干扰新栈安装验证；仅影响本次脚本。
export VLLM_PLUGINS=ascend
export TORCH_DEVICE_BACKEND_AUTOLOAD=0
export PYTHONUNBUFFERED=1
unset SETUPTOOLS_SCM_PRETEND_VERSION SETUPTOOLS_SCM_PRETEND_VERSION_FOR_VLLM
unset SETUPTOOLS_SCM_PRETEND_VERSION_FOR_VLLM_ASCEND VLLM_VERSION_OVERRIDE
export ASCEND_HOME_PATH="${ASCEND_HOME_PATH:-${ASCEND_TOOLKIT_HOME:-/usr/local/Ascend/ascend-toolkit/latest}}"
export ASCEND_TOOLKIT_HOME="${ASCEND_TOOLKIT_HOME:-$ASCEND_HOME_PATH}"

STAGE='1/5 基础检查'
echo "[INFO] $STAGE；源码目录：$BUILD_ROOT"
echo '[WARN] 将更新当前 Python 环境中的 vLLM/vLLM-Ascend；建议使用专用容器。'
[[ -d "$ASCEND_HOME_PATH" ]] || { echo "[ERROR] CANN 目录不存在：$ASCEND_HOME_PATH"; exit 1; }
"$PYTHON" - "$CONSTRAINTS" <<'PY'
import importlib.metadata as md
import ssl
import subprocess
import sys
if sys.version_info < (3, 11):
    raise RuntimeError("最新源码脚本要求 Python >= 3.11")
import torch
import torch_npu
print("[env] Python:", sys.version.split()[0], "OpenSSL:", ssl.OPENSSL_VERSION)
print("[env] Git from Python:", subprocess.check_output(["git", "--version"], text=True).strip())
if torch.npu.device_count() < 1:
    raise RuntimeError("未检测到 NPU；请先配置 torch_npu/CANN/设备映射")
print("[env] NPU:", torch.npu.get_device_name(0))
# 约束所有 pip 安装，不静默替换基础镜像的 torch/NPU 配套包。
with open(sys.argv[1], "w") as target:
    for name in ("torch", "torch-npu", "torchvision", "torchaudio"):
        try:
            version = md.version(name)
        except md.PackageNotFoundError:
            continue
        target.write(f"{name}=={version}\n")
        print(f"[env] preserve {name}=={version}")
PY
if [[ -z "${SOC_VERSION:-}" ]]; then
    SOC_VERSION="$("$PYTHON" - <<'PY'
import re
import torch
import torch_npu
name = torch.npu.get_device_name(0)
match = re.fullmatch(r"Ascend[A-Za-z0-9_]+", name)
if not match:
    raise RuntimeError(f"无法识别 {name!r}；请显式设置 SOC_VERSION")
print(name.lower())
PY
)"
fi
export SOC_VERSION
echo "[env] SOC_VERSION=$SOC_VERSION；CANN=$ASCEND_HOME_PATH"

update_repo()
{
    local url="$1" dir="$2" actual catlass_commit
    if [[ ! -e "$dir" ]]; then
        git clone --branch main "$url" "$dir"
    fi
    [[ -e "$dir/.git" ]] || { echo "[ERROR] 已存在但不是仓库：$dir"; return 1; }
    actual="$(git -C "$dir" remote get-url origin)"
    [[ "${actual%.git}" == "${url%.git}" ]] || { echo "[ERROR] origin 与预期不符：$dir"; return 1; }
    if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
        echo "[ERROR] 源码有本地改动，停止更新；请自行提交或备份：$dir"
        return 1
    fi
    if [[ "$(git -C "$dir" rev-parse --is-shallow-repository)" == true ]]; then
        git -C "$dir" fetch --unshallow origin
    fi
    git -C "$dir" fetch --tags origin '+refs/heads/main:refs/remotes/origin/main'
    git -C "$dir" checkout --detach refs/remotes/origin/main
    git -C "$dir" submodule sync --recursive
    git -C "$dir" submodule update --init --recursive
    # Ascend 的算子构建还会读取这个自定义 pin，提前按同一版本准备依赖。
    if [[ -f "$dir/.gitmodules" ]] && catlass_commit="$(
        git config -f "$dir/.gitmodules" --get submodule.csrc/third_party/catlass.commit
    )"; then
        git -C "$dir/csrc/third_party/catlass" fetch origin
        git -C "$dir/csrc/third_party/catlass" checkout --detach "$catlass_commit"
        git -C "$dir/csrc/third_party/catlass" submodule update --init --recursive
    fi
    git -C "$dir" log -1 --format='%H %s'
}

STAGE='2/5 拉取两个最新 main'
echo "[INFO] $STAGE"
update_repo "$VLLM_URL" "$VLLM_DIR"
update_repo "$VLLM_ASCEND_URL" "$ASCEND_DIR"
{
    printf 'vllm '; git -C "$VLLM_DIR" rev-parse HEAD
    printf 'vllm-ascend '; git -C "$ASCEND_DIR" rev-parse HEAD
} | tee "$BUILD_ROOT/logs/commits_${RUN_ID}.txt"
if [[ -f "$ASCEND_DIR/.github/vllm-main-verified.commit" ]]; then
    echo '[INFO] Ascend 记录的已验证 vLLM commit（仅提示，不自动回退）：'
    cat "$ASCEND_DIR/.github/vllm-main-verified.commit"
fi
echo '[WARN] 两个最新 main 不一定兼容；依赖冲突时停止，不替换 torch/torch_npu。'

STAGE='3/5 编译安装 vLLM empty'
echo "[INFO] $STAGE"
cd "$VLLM_DIR"
helper=tools/use_existing_torch.py
[[ -f "$helper" ]] || helper=use_existing_torch.py
[[ -f "$helper" ]] || { echo '[ERROR] 上游 use_existing_torch.py 未找到'; exit 1; }
helper_status=0
"$PYTHON" "$helper" || helper_status=$?
git diff --binary -- pyproject.toml requirements > "$HELPER_PATCH"
[[ "$helper_status" -eq 0 ]] || exit "$helper_status"

install_build_requirements()
{
    local repo="$1" requirements
    requirements="$("$PYTHON" - "$repo/pyproject.toml" <<'PY'
import sys
import tomllib
from packaging.requirements import Requirement
with open(sys.argv[1], "rb") as source:
    requirements = tomllib.load(source)["build-system"]["requires"]
for entry in requirements:
    if Requirement(entry).name.lower().replace("_", "-") not in {
        "torch", "torch-npu", "torchvision", "torchaudio", "vllm"
    }:
        print(entry)
PY
)"
    local items=()
    mapfile -t items <<< "$requirements"
    "$PYTHON" -m pip install -c "$CONSTRAINTS" "${items[@]}"
}
"$PYTHON" -m pip install -c "$CONSTRAINTS" packaging
install_build_requirements "$VLLM_DIR"
VLLM_TARGET_DEVICE=empty "$PYTHON" -m pip install -c "$CONSTRAINTS" -e . --no-build-isolation
if [[ -s "$HELPER_PATCH" ]]; then
    git apply --reverse "$HELPER_PATCH"
    : > "$HELPER_PATCH"
fi
# 不在此处 import vllm，避免提前激活尚未安装完成的 Ascend 插件。

STAGE='4/5 编译安装 vLLM-Ascend'
echo "[INFO] $STAGE"
cd "$ASCEND_DIR"
install_build_requirements "$ASCEND_DIR"
unset LD_PRELOAD
SOC_VERSION="$SOC_VERSION" COMPILE_CUSTOM_KERNELS=1 \
    "$PYTHON" -m pip install -c "$CONSTRAINTS" -e . --no-build-isolation

STAGE='5/5 完整导入与依赖检查'
echo "[INFO] $STAGE"
"$PYTHON" - "$VLLM_DIR" "$ASCEND_DIR" <<'PY'
import importlib.metadata as md
from pathlib import Path
import sys
import torch
import torch_npu
import vllm
import vllm_ascend
from vllm_ascend import _build_info
from vllm.platforms import current_platform
for package, module, directory in (
    ("vllm", vllm, sys.argv[1]),
    ("vllm-ascend", vllm_ascend, sys.argv[2]),
):
    path = Path(module.__file__).resolve()
    if not path.is_relative_to(Path(directory).resolve()):
        raise RuntimeError(f"{package} 加载了错误目录：{path}")
    print(f"[OK] {package} {md.version(package)} @ {path}")
print("[OK] build info:", _build_info.__file__)
print("[OK] platform:", current_platform.device_type)
if current_platform.device_type != "npu":
    raise RuntimeError("Ascend 平台未正确激活")
print("[OK] NPU:", torch.npu.get_device_name(0))
PY
"$PYTHON" -m pip check
echo "[DONE] 两个最新 main 构建安装及导入检查通过；尚未测试模型推理。"
echo "[DONE] 完整日志：$LOG_FILE"
