#!/usr/bin/env bash
#
# =============================================================================
# afd_build_and_compile.sh
#
# A5 / Ascend950 AFD 推理栈一键构建脚本
#
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
# !!! 重要：首次使用必须添加 --force 参数                              !!!
# !!!                                                                        !!!
# !!!   bash afd_build_and_compile.sh --force                                !!!
# !!!                                                                        !!!
# !!! 新容器可能复用 /home 下旧的源码和 build stamp，但容器内 Python 包    !!!
# !!! 仍来自基础镜像。不加 --force 可能错误跳过 vLLM / vLLM-Ascend 安装。   !!!
# !!! 只有确认当前容器已经完整构建成功后，后续执行才可以不加 --force。       !!!
# !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
#
# 构建失败先看同目录的排查文档：
#
#   vllm_ascend_build_troubleshooting.md
#
# 里面写清了两类最常见失败的判定与修复：
#   1. 与 CANN 9.2 内置算子撞名（报 "in op store" / "'NoneType' object is not subscriptable"）
#   2. 算子改名后 csrc/build 残留（报 "not any obj compile success"）
#
#
# 前提：
#   1. 已经进入 Docker 容器
#   2. proxy 已经在进入容器时自动 source
#   3. pip / git proxy 已经配置完成
#   4. 基础镜像已经包含可用的 torch / torch_npu
#
#
# 仓库策略：
#
#   vLLM
#     repo:
#       https://github.com/vllm-project/vllm.git
#
#     ref:
#       v0.30.0 (commit ced6857a)
#
#     特殊处理：
#       只获取 v0.30.0
#       depth = 1
#
#
#   vLLM-Ascend
#     repo:
#       https://github.com/vllm-project/vllm-ascend.git
#
#     commit:
#       8d4409d6
#
#     处理：
#       正常 git clone 整个仓库
#       checkout 8d4409d6
#       cherry-pick PR #17998 的改名提交
#       （kda_gate_cumsum -> kda_gate_cumsum_vllm，见第 9b 节）
#       再给另外两个撞名算子改名
#       （chunk_gated_delta_rule_fwd_h / causal_conv1d，见第 9c 节）
#       共新增两个 commit，HEAD 不再等于 8d4409d6
#
#
#   afd-plugin
#     repo:
#       https://github.com/Pingzii/afd-plugin.git
#
#     branch:
#       main
#
#     处理：
#       正常 git clone 整个仓库
#       checkout main
#       通过 vllm.general_plugins entry point 安装 AFD
#       不修改 vLLM / vLLM-Ascend 源码树
#
#
# 编译顺序：
#
#   clone / checkout
#        ↓
#   vLLM empty
#        ↓
#   vLLM-Ascend
#        ↓
#   afd-plugin
#        ↓
#   完整验证
#
#
# 首次执行（必须）：
#
#   bash afd_build_and_compile.sh --force
#
#
# 后续执行（确认当前容器已经完整构建成功）：
#
#   bash afd_build_and_compile.sh
#
#
# 本脚本不会：
#
#   - source proxy.sh
#   - 创建 Docker
#   - 修改 Docker 配置
#   - 应用下面这一条以外的任何 patch
#
#
# 唯一的源码改动：
#
#   vllm-ascend 上给三个与 CANN 9.2 内置算子撞名的自定义算子换独立符号：
#
#     kda_gate_cumsum              -> kda_gate_cumsum_vllm
#         cherry-pick PR #17998，见第 9b 节
#     chunk_gated_delta_rule_fwd_h -> chunk_gated_delta_rule_fwd_h_vllm
#     causal_conv1d                -> causal_conv1d_vllm
#         见第 9c 节
#
#   共产生两个 commit，只改符号名，不改任何计算逻辑。
#
#   该改动是确定性的：同一个基线 commit 上重复执行会得到同一个 commit SHA，
#   所以 build stamp 依然有效，不会每次重复编译 vLLM-Ascend。
#   升级脚本后第一次执行会因为 HEAD 变化而重新编译一次 vLLM-Ascend。
#
# =============================================================================

set -euo pipefail


# =============================================================================
# 0. 参数
# =============================================================================

FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=1
            ;;

        *)
            echo "[ERROR] Unknown argument: $arg"
            echo
            echo "Usage:"
            echo "  bash $0"
            echo "  bash $0 --force"
            exit 2
            ;;
    esac
done


# =============================================================================
# 1. 全局配置
# =============================================================================

# -----------------------------------------------------------------------------
# AFD 根目录
#
# 最终目录结构：
#
# /home/s00988495/AFD/
#
# ├── vllm/
# ├── vllm-ascend/
# ├── afd-plugin/
#
# ├── logs/
# │   └── afd_build_all.log
#
# └── .build_stamps/
#     ├── vllm
#     ├── vllm-ascend
#     └── afd-plugin
#
# -----------------------------------------------------------------------------

ROOT="${AFD_ROOT:-/home/s00988495/AFD}"


# -----------------------------------------------------------------------------
# LOG
#
# 用于记录：
#
#   “整个构建过程中发生了什么”
#
# 包括：
#
#   git clone
#   git fetch
#   git checkout
#   pip install
#   编译输出
#   Python import
#   ERROR
#
# 所有输出：
#
#   1. 正常显示在终端
#   2. 同时写入：
#
#      /home/s00988495/AFD/logs/afd_build_all.log
#
# -----------------------------------------------------------------------------

LOG_DIR="${ROOT}/logs"

LOG="${LOG_DIR}/afd_build_all.log"


# -----------------------------------------------------------------------------
# Build Stamp
#
# .build_stamps 不是 Git 自带功能，
# 是这个脚本自己维护的“成功编译记录”。
#
# 例如：
#
#   .build_stamps/vllm-ascend
#
# 里面保存：
#
#   上一次成功 build 时对应仓库的 Git HEAD
#
#
# 下一次执行：
#
#   当前 HEAD == stamp
#
#       ↓
#
#   说明该源码版本已经成功 build
#
#       ↓
#
#   跳过 build
#
#
# 如果：
#
#   当前 HEAD != stamp
#
#       ↓
#
#   源码发生变化
#
#       ↓
#
#   重新 build
#
#
# 所以：
#
#   LOG
#     = 构建过程记录
#
#   STAMP_DIR
#     = 已成功编译版本记录
#
# -----------------------------------------------------------------------------

STAMP_DIR="${ROOT}/.build_stamps"


# =============================================================================
# 2. 仓库版本
# =============================================================================

# -----------------------------------------------------------------------------
# vLLM
#
# 只获取 v0.30.0，depth=1，并校验目标 commit。
# -----------------------------------------------------------------------------

VLLM_URL="https://github.com/vllm-project/vllm.git"

VLLM_REF="v0.30.0"

VLLM_COMMIT="ced6857afa0ea7b2e3f0846a62e1394e90f15607"


# -----------------------------------------------------------------------------
# vLLM-Ascend
#
# 正常完整 clone，然后 checkout 固定 commit，
# 再 cherry-pick PR #17998 的改名提交。
# -----------------------------------------------------------------------------

VLLM_ASCEND_URL="https://github.com/vllm-project/vllm-ascend.git"

VLLM_ASCEND_COMMIT="8d4409d6256d8a6729140ddcc0d1889e3f96cdd6"


# -----------------------------------------------------------------------------
# vLLM-Ascend PR #17998
#
#   https://github.com/vllm-project/vllm-ascend/pull/17998
#
#   [Refactor][Ops] Rename KDA gate cumsum custom op with vllm suffix
#
# 取该 PR 的改名提交，cherry-pick 到上面的 VLLM_ASCEND_COMMIT 上。
# 细节和冲突处理见第 9b 节。
# -----------------------------------------------------------------------------

VLLM_ASCEND_PR_NUMBER=17998

VLLM_ASCEND_PR_COMMIT="4f869f9a8d3257e243fdd8fd9d998231f069ffe8"


# 固定时间与 committer 身份，保证重复执行得到同一个 commit SHA，
# 否则 build stamp 每次都会失效、每次都重新编译 vLLM-Ascend。
VLLM_ASCEND_PR_DATE="2026-10-08T15:30:23+08:00"

VLLM_ASCEND_PR_AUTHOR="Foriv <2293567056@qq.com>"

VLLM_ASCEND_PR_COMMITTER_NAME="AFD build script"

VLLM_ASCEND_PR_COMMITTER_EMAIL="afd-build@localhost"


# -----------------------------------------------------------------------------
# afd-plugin
#
# 正常完整 clone，使用 main。
# -----------------------------------------------------------------------------

AFD_PLUGIN_URL="https://github.com/Pingzii/afd-plugin.git"

AFD_PLUGIN_BRANCH="main"


# =============================================================================
# 3. 创建目录
# =============================================================================

mkdir -p \
    "$ROOT" \
    "$LOG_DIR" \
    "$STAMP_DIR"


# =============================================================================
# 4. 日志
#
# tee -a：
#
#   输出显示到终端
#       +
#   追加写入日志
#
# 2>&1：
#
#   stderr 合并到 stdout
#
# =============================================================================

exec > >(tee -a "$LOG") 2>&1


step()
{
    echo
    echo "==================================================================="
    echo ">>> $1"
    echo "==================================================================="
    echo
}


# =============================================================================
# 5. 基础环境检查
# =============================================================================

step "0/5 检查基础环境"


echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!! 重要：首次使用必须运行："
echo "!!!"
echo "!!!   bash afd_build_and_compile.sh --force"
echo "!!!"
echo "!!! 不带 --force 只适用于当前容器已经完整构建成功后的重复执行。"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo

if [[ "$FORCE" -eq 1 ]]; then
    echo "[INFO] --force 已启用：将从零 clone 并重新 build。"
else
    echo "[WARN] 当前未使用 --force。"
    echo "[WARN] 如果这是首次使用，请立即停止并改用："
    echo "[WARN] bash afd_build_and_compile.sh --force"
fi


if ! command -v git >/dev/null 2>&1; then
    echo "[ERROR] git not found."
    exit 1
fi


if ! command -v python3 >/dev/null 2>&1; then
    echo "[ERROR] python3 not found."
    exit 1
fi


echo "[env] Python:"
python3 --version


echo
echo "[env] pip:"
python3 -m pip --version


echo
echo "[env] git:"
git --version


echo
echo "[env] pip index:"
python3 -m pip config get \
    global.index-url \
    2>/dev/null || true


echo
echo "[env] git http.proxy:"
git config --global \
    --get http.proxy \
    2>/dev/null || true


# =============================================================================
# 6. torch / torch_npu 检查
# =============================================================================

echo
echo "[env] Checking torch / torch_npu..."


python3 - <<'PY'
import torch
import torch_npu

print("torch     =", torch.__version__)
print("torch_npu =", torch_npu.__version__)

if not hasattr(torch, "npu"):
    raise RuntimeError("torch.npu is unavailable")

count = torch.npu.device_count()

print("NPU count =", count)

if count <= 0:
    raise RuntimeError("No NPU detected")

print("NPU 0     =", torch.npu.get_device_name(0))
PY


# =============================================================================
# 7. SOC_VERSION 探测
#
# 例如：
#
#   Ascend950PR_957d
#
# 转换为：
#
#   ascend950pr_957d
#
# =============================================================================

detect_soc()
{
    python3 - <<'PY'
import re
import torch
import torch_npu

name = torch.npu.get_device_name(0)

m = re.match(r"(Ascend\w+)_(\w+)", name)

if m:
    print((m.group(1) + "_" + m.group(2)).lower())
else:
    print("ascend950")
PY
}


SOC_VERSION="${SOC_VERSION:-$(detect_soc)}"


echo
echo "[env] SOC_VERSION=$SOC_VERSION"


# =============================================================================
# 8. Clone vLLM
#
# vLLM 仓库较大，所以特殊处理：
#
#   只获取：
#
#       v0.30.0
#
#   depth：
#
#       1
#
#
# 实际命令：
#
#   git clone
#       --branch v0.30.0
#       --single-branch
#       --depth 1
#
#
# 注意：
#
# v0.30.0 是 tag，
# 但 git clone --branch 同样支持指定 tag。
#
# =============================================================================

clone_vllm()
{
    local dir="$ROOT/vllm"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] vllm"
    echo "[repo] URL   : $VLLM_URL"
    echo "[repo] ref   : $VLLM_REF"
    echo "[repo] depth : 1"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old vllm"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次 clone
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] vLLM uses shallow clone."
        echo "[clone] Only downloading:"
        echo "        ref   = $VLLM_REF"
        echo "        depth = 1"
        echo
        echo "[clone] Full vLLM Git history will NOT be downloaded."
        echo


        git clone \
            --branch "$VLLM_REF" \
            --single-branch \
            --depth 1 \
            "$VLLM_URL" \
            "$dir"


    else

        echo
        echo "[clone] vLLM already exists."
        echo "[clone] Skip clone."


        # 如果之前已有仓库但 tag 不存在，
        # 只 fetch 需要的 tag。
        if ! git -C "$dir" \
            rev-parse \
            "$VLLM_REF^{commit}" \
            >/dev/null 2>&1; then

            echo
            echo "[git] $VLLM_REF not found locally."
            echo "[git] Fetching only specified ref with depth=1."


            git -C "$dir" fetch \
                --depth 1 \
                origin \
                "refs/tags/$VLLM_REF:refs/tags/$VLLM_REF"

        fi

    fi


    # -------------------------------------------------------------------------
    # 固定版本构建：
    #
    # detached HEAD 到指定 tag。
    # -------------------------------------------------------------------------

    git -C "$dir" checkout \
        --detach \
        "$VLLM_REF"


    local actual_head

    actual_head="$(git -C "$dir" rev-parse HEAD)"

    if [[ "$actual_head" != "$VLLM_COMMIT" ]]; then
        echo "[ERROR] vLLM HEAD mismatch."
        echo "        expected: $VLLM_COMMIT"
        echo "        actual  : $actual_head"
        exit 1
    fi


    echo
    echo "[git] vLLM HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
    echo "[git] shallow repository:"

    git -C "$dir" rev-parse \
        --is-shallow-repository


    echo
}


# =============================================================================
# 9. Clone vLLM-Ascend
#
# vLLM-Ascend：
#
#   正常 git clone
#
# 不使用：
#
#   --depth
#   --single-branch
#
#
# 即下载正常完整 Git 仓库。
#
# clone 完以后：
#
#   checkout --detach 8d4409d6
#
# =============================================================================

clone_vllm_ascend()
{
    local dir="$ROOT/vllm-ascend"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] vllm-ascend"
    echo "[repo] URL    : $VLLM_ASCEND_URL"
    echo "[repo] commit : $VLLM_ASCEND_COMMIT"
    echo "[repo] clone  : normal full git clone"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old vllm-ascend"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次：
    #
    # 正常完整 clone。
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] Normal cloning vLLM-Ascend."
        echo "[clone] Full repository/history will be downloaded."
        echo


        git clone \
            "$VLLM_ASCEND_URL" \
            "$dir"


    else

        echo
        echo "[clone] vLLM-Ascend already exists."
        echo "[clone] Skip clone."


        # ---------------------------------------------------------------------
        # 如果之前这个目录是旧脚本创建的 shallow repository，
        #
        # 这里恢复成完整 Git 历史。
        # ---------------------------------------------------------------------

        if [[ "$(
            git -C "$dir" rev-parse --is-shallow-repository
        )" == "true" ]]; then

            echo
            echo "[git] Existing vLLM-Ascend repository is shallow."
            echo "[git] Converting it to full repository..."


            git -C "$dir" fetch \
                --unshallow \
                origin

        else

            echo
            echo "[git] Fetching latest remote refs..."

            git -C "$dir" fetch \
                origin \
                --tags

        fi

    fi


    # -------------------------------------------------------------------------
    # 检查 commit
    # -------------------------------------------------------------------------

    if ! git -C "$dir" cat-file \
        -e "${VLLM_ASCEND_COMMIT}^{commit}" \
        2>/dev/null; then

        echo
        echo "[git] Commit not available locally."
        echo "[git] Fetching the exact vLLM-Ascend commit..."


        git -C "$dir" fetch \
            origin \
            "$VLLM_ASCEND_COMMIT"


        if ! git -C "$dir" cat-file \
            -e "${VLLM_ASCEND_COMMIT}^{commit}" \
            2>/dev/null; then

            echo
            echo "[ERROR] Cannot find vLLM-Ascend commit:"
            echo "        $VLLM_ASCEND_COMMIT"

            exit 1

        fi

    fi


    # -------------------------------------------------------------------------
    # checkout commit
    # -------------------------------------------------------------------------

    echo
    echo "[git] Checkout vLLM-Ascend commit:"
    echo "      $VLLM_ASCEND_COMMIT"


    git -C "$dir" checkout \
        --detach \
        "$VLLM_ASCEND_COMMIT"


    local actual_head

    actual_head="$(git -C "$dir" rev-parse HEAD)"

    if [[ "$actual_head" != "$VLLM_ASCEND_COMMIT" ]]; then
        echo "[ERROR] vLLM-Ascend HEAD mismatch."
        echo "        expected: $VLLM_ASCEND_COMMIT"
        echo "        actual  : $actual_head"
        exit 1
    fi


    echo
    echo "[git] vLLM-Ascend HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
}


# =============================================================================
# 9b. vLLM-Ascend: cherry-pick PR #17998
#
# 上游 PR：
#
#   https://github.com/vllm-project/vllm-ascend/pull/17998
#
#   [Refactor][Ops] Rename KDA gate cumsum custom op with vllm suffix
#
# 该 PR 把 csrc/attention/kda_gate_cumsum 下的整条算子链（OpDef、tiling、
# kernel、ACLNN、Torch / Meta 注册、A2/A3/A5 编译列表、调用方）改名为
# kda_gate_cumsum_vllm / KdaGateCumsumVllm，让 vLLM 自定义算子拥有独立符号，
# 不再与 FLA 的同名算子冲突。
# 参数、张量布局、计算逻辑和实现源码都不变。
#
#
# 为什么不能直接 git cherry-pick：
#
#   本脚本固定 VLLM_ASCEND_COMMIT = 8d4409d6，
#   而该 PR 的基线是 dd87d93c，两者相差 166 个 commit。
#   其中四个共享文件被这 166 个 commit 改过：
#
#     csrc/build_aclnn.sh
#     csrc/torch_binding.cpp
#     csrc/torch_binding_meta.cpp
#     tests/e2e/nightly/single_node/ops/singlecard_ops/test_chunk_kda_aclnn.py
#
#   直接 cherry-pick 会在这四个文件上冲突。
#
#   已逐个核对：该 PR 对这四个文件的改动只有标识符改名，
#   所以按“本基线原文 + 同样的改名”解决，结果与该 PR 的语义一致。
#
#
# 本基线额外的两个引用：
#
#   下面两个文件在 8d4409d6 上仍然引用旧名字，
#   但在该 PR 的基线上已经不存在（上游不再引用），所以上游没有改它们，
#   这里必须一起改，否则目录改名后编译会失败：
#
#     csrc/attention/chunk_kda_fwd/op_host/CMakeLists.txt
#     csrc/attention/chunk_kda_fwd/op_kernel/chunk_kda_fwd_common.h
#
#
# 结果：
#
#   cherry-pick 作为本仓库的一个 commit 保存，工作树保持干净：
#
#     HEAD = VLLM_ASCEND_COMMIT + 这一个 commit
#
#   author 保持上游作者，committer 身份与提交时间固定，
#   因此同一个基线 commit 上重复执行会得到同一个 commit SHA。
# =============================================================================


# 对该 PR 涉及的文件套用改名。
rename_kda_gate_cumsum()
{
    sed -i \
        -e 's/kda_gate_cumsum/kda_gate_cumsum_vllm/g' \
        -e 's/KdaGateCumsum/KdaGateCumsumVllm/g' \
        "$1"
}


apply_vllm_ascend_pr_17998()
{
    local dir="$ROOT/vllm-ascend"


    # -------------------------------------------------------------------------
    # 该 PR 会冲突的四个文件（本基线与该 PR 基线之间被其它 commit 改过）。
    # -------------------------------------------------------------------------

    local conflict_files=(
        "csrc/build_aclnn.sh"
        "csrc/torch_binding.cpp"
        "csrc/torch_binding_meta.cpp"
        "tests/e2e/nightly/single_node/ops/singlecard_ops/test_chunk_kda_aclnn.py"
    )


    # -------------------------------------------------------------------------
    # 本基线额外引用旧名字的文件（该 PR 的基线上已不存在）。
    # -------------------------------------------------------------------------

    local extra_files=(
        "csrc/attention/chunk_kda_fwd/op_host/CMakeLists.txt"
        "csrc/attention/chunk_kda_fwd/op_kernel/chunk_kda_fwd_common.h"
    )


    # 该 PR 改动 17 个文件，加上上面两个额外文件，共 19 个。
    local expected_paths=19


    cd "$dir"


    echo
    echo "-------------------------------------------------------------------"
    echo "[pr] vLLM-Ascend PR #$VLLM_ASCEND_PR_NUMBER"
    echo "[pr] commit : $VLLM_ASCEND_PR_COMMIT"
    echo "[pr] base   : $VLLM_ASCEND_COMMIT"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # 基线本来就包含改名（例如以后把 VLLM_ASCEND_COMMIT 提到该 PR 之后）。
    # -------------------------------------------------------------------------

    if [[ ! -d csrc/attention/kda_gate_cumsum ]] && \
       [[ -d csrc/attention/kda_gate_cumsum_vllm ]]; then

        echo "[pr] 当前 commit 已包含该改名，跳过 cherry-pick。"

        return 0
    fi


    if [[ ! -d csrc/attention/kda_gate_cumsum ]]; then

        echo "[ERROR] 找不到改名前目录："
        echo "        $dir/csrc/attention/kda_gate_cumsum"

        exit 1
    fi


    # -------------------------------------------------------------------------
    # 上一次运行如果中断在这里，会留下未提交的改动；
    # 先归位到基线 commit，保证每次从同一个状态开始。
    # -------------------------------------------------------------------------

    if [[ -n "$(
        git status --porcelain
    )" ]]; then

        echo "[WARN] vllm-ascend 工作树不干净（可能是上次运行留下的中间状态）。"
        echo "[WARN] 重置到基线 commit：$VLLM_ASCEND_COMMIT"

        git reset --hard "$VLLM_ASCEND_COMMIT"
    fi


    # -------------------------------------------------------------------------
    # 确保 PR commit 在本地。
    #
    # 完整 clone 的上游 main 已经包含这个提交（该 PR 已合入），
    # 缺失时才需要 fetch。
    # -------------------------------------------------------------------------

    if ! git cat-file \
        -e "${VLLM_ASCEND_PR_COMMIT}^{commit}" \
        2>/dev/null; then

        echo
        echo "[pr] 本地缺少该 commit，尝试获取。"

        if ! git fetch \
            origin \
            "refs/pull/${VLLM_ASCEND_PR_NUMBER}/head"; then

            echo "[pr] refs/pull 获取失败，改为直接获取 commit。"

            git fetch \
                origin \
                "$VLLM_ASCEND_PR_COMMIT"
        fi
    fi


    if ! git cat-file \
        -e "${VLLM_ASCEND_PR_COMMIT}^{commit}" \
        2>/dev/null; then

        echo
        echo "[ERROR] 无法获取 PR commit："
        echo "        $VLLM_ASCEND_PR_COMMIT"

        exit 1
    fi


    # -------------------------------------------------------------------------
    # cherry-pick，但先不 commit。
    #
    # 已知会在这四个文件上冲突，冲突解决后再生成 commit。
    # -------------------------------------------------------------------------

    echo
    echo "[pr] cherry-pick --no-commit $VLLM_ASCEND_PR_COMMIT"


    local rc=0

    git cherry-pick \
        --no-commit \
        "$VLLM_ASCEND_PR_COMMIT" || rc=$?


    local unmerged

    unmerged="$(
        git diff \
            --name-only \
            --diff-filter=U
    )"


    # 失败但又没有冲突文件，说明不是预期的冲突场景，不能继续。
    if [[ "$rc" -ne 0 && -z "$unmerged" ]]; then

        echo
        echo "[ERROR] cherry-pick 失败，且没有冲突文件，无法按预期解决。"

        git reset --hard "$VLLM_ASCEND_COMMIT"

        exit 1
    fi


    # -------------------------------------------------------------------------
    # 冲突必须只出现在已知的四个文件里。
    # 一旦出现别的冲突，说明本基线与预期不符，
    # 立即失败，绝不让改了一半的源码树进入编译。
    # -------------------------------------------------------------------------

    local f
    local candidate
    local known

    while IFS= read -r f; do

        [[ -z "$f" ]] && continue

        known=0

        for candidate in "${conflict_files[@]}"; do

            if [[ "$f" == "$candidate" ]]; then
                known=1
            fi
        done

        if [[ "$known" -eq 0 ]]; then

            echo
            echo "[ERROR] 出现预期外的冲突文件："
            echo "        $f"

            git reset --hard "$VLLM_ASCEND_COMMIT"

            exit 1
        fi

    done <<< "$unmerged"


    # -------------------------------------------------------------------------
    # 解决冲突：
    #
    #   取本基线原文（HEAD），再套用该 PR 的改名。
    #
    # 该 PR 对这四个文件的改动只有改名，所以这里等价于该 PR 的改法；
    # 没有冲突的文件用同样方式处理也不会改变结果。
    # -------------------------------------------------------------------------

    for f in "${conflict_files[@]}"; do

        git checkout \
            HEAD \
            -- "$f"

        rename_kda_gate_cumsum "$f"

        git add "$f"

        echo "[pr] 按基线原文 + 改名解决：$f"
    done


    # -------------------------------------------------------------------------
    # 本基线额外引用旧名字的两个文件。
    # -------------------------------------------------------------------------

    for f in "${extra_files[@]}"; do

        if [[ ! -f "$f" ]]; then

            echo
            echo "[ERROR] 缺少文件："
            echo "        $dir/$f"

            git reset --hard "$VLLM_ASCEND_COMMIT"

            exit 1
        fi

        rename_kda_gate_cumsum "$f"

        git add "$f"

        echo "[pr] 基线额外引用改名：$f"
    done


    # -------------------------------------------------------------------------
    # 生成 commit。
    #
    # author     ：保持上游作者与作者时间
    # committer  ：固定身份与时间，保证 SHA 稳定
    # --no-verify：不触发仓库 git hook
    # -------------------------------------------------------------------------

    GIT_AUTHOR_DATE="$VLLM_ASCEND_PR_DATE" \
    GIT_COMMITTER_DATE="$VLLM_ASCEND_PR_DATE" \
    GIT_COMMITTER_NAME="$VLLM_ASCEND_PR_COMMITTER_NAME" \
    GIT_COMMITTER_EMAIL="$VLLM_ASCEND_PR_COMMITTER_EMAIL" \
    git commit \
        --quiet \
        --no-verify \
        --author="$VLLM_ASCEND_PR_AUTHOR" \
        -m "refactor(ops): namespace KDA gate cumsum with vllm suffix" \
        -m "Port of vllm-project/vllm-ascend#${VLLM_ASCEND_PR_NUMBER} onto ${VLLM_ASCEND_COMMIT}.

(cherry picked from commit ${VLLM_ASCEND_PR_COMMIT})

The four shared files conflict at this pin because it predates the upstream
base by 166 commits; they are resolved by re-applying the same identifier
rename to the pin's own content. Two files that still reference the old
names at this pin (csrc/attention/chunk_kda_fwd/op_host/CMakeLists.txt and
csrc/attention/chunk_kda_fwd/op_kernel/chunk_kda_fwd_common.h) are renamed
too; they no longer exist upstream at the PR base."


    # -------------------------------------------------------------------------
    # 结果校验：任何一项不通过就回退到基线 commit 并退出。
    # -------------------------------------------------------------------------

    local changed

    changed="$(
        git diff \
            --name-only \
            "$VLLM_ASCEND_COMMIT" \
            HEAD \
        | wc -l \
        | tr -d ' '
    )"


    if [[ "$changed" != "$expected_paths" ]]; then

        echo
        echo "[ERROR] 改动文件数不符合预期。"
        echo "        expected: $expected_paths"
        echo "        actual  : $changed"

        git reset --hard "$VLLM_ASCEND_COMMIT"

        exit 1
    fi


    # 旧算子名必须一个都不剩；
    # kda_gate_cumsum_vllm / KdaGateCumsumVllm 不算残留。
    local stale

    stale="$(
        git grep \
            -n \
            -E 'kda_gate_cumsum([^_]|$)|KdaGateCumsum([^V]|$)' \
            HEAD \
            -- . \
            || true
    )"


    if [[ -n "$stale" ]]; then

        echo
        echo "[ERROR] 仍然存在旧算子名："
        echo "$stale"

        git reset --hard "$VLLM_ASCEND_COMMIT"

        exit 1
    fi


    # 后面 afd-plugin 的“不得修改源码树”校验依赖干净工作树。
    if [[ -n "$(
        git status --porcelain
    )" ]]; then

        echo
        echo "[ERROR] cherry-pick 后工作树不干净："

        git status --short

        git reset --hard "$VLLM_ASCEND_COMMIT"

        exit 1
    fi


    echo
    echo "[pr] cherry-pick 完成，HEAD:"

    git log \
        --oneline \
        -1

    echo
}


# =============================================================================
# 9c. vLLM-Ascend: 其余与 CANN 9.2 内置算子撞名的自定义算子
#
# 背景（2026-10-16 绿区实测结论）：
#
#   CANN 9.2 自带一套 ops_transformer 内置算子：
#
#     /usr/local/Ascend/cann-9.2.0/opp/built-in/op_impl/ai_core/tbe/kernel/
#       ascend950/ops_transformer/<operator>_apt/
#
#   编译自定义算子时，OPC 会拿本仓库的算子定义与 op store 里的同名内置算子
#   比对；名字相同但 ABI 不同就直接失败：
#
#     CausalConv1d            : invalid input nums[8], should equal 12 in op store
#     ChunkGatedDeltaRuleFwdH : op_info_parser ... NoneType object is not subscriptable
#     KdaGateCumsum           : 同一类（已由第 9b 节的 #17998 解决，实测 6/6 Done）
#
#   内置算子删不掉（动了整个 toolkit 就坏了），只能给本仓库的算子换独立符号。
#   这就是上游一直用 _vllm 后缀的原因。
#
#
# 本节做两件改名（只改符号名，不改任何计算逻辑）：
#
#   1. moe/chunk_gated_delta_rule_fwd_h -> moe/chunk_gated_delta_rule_fwd_h_vllm
#
#      对照上游 PR #17997（Restore custom GDN FwdH with vllm-specific names）。
#      已逐文件核对：该 PR 对 52 个文件的改动里，47 个恰好等于下面这三档改名
#      （小写 / CamelCase / 大写 include guard）。
#
#      该 PR 同时把 python 路径从 fla_npu 切回内置算子；本基线早于 #17727，
#      本来就还在用内置算子，所以那部分不需要、也不采纳。
#
#   2. moe/causal_conv1d -> moe/causal_conv1d_vllm
#
#      上游 #17727 是删掉它、改走 fla_npu；但本基线的 glm5next 仍然通过
#      torch.ops._C_ascend.npu_causal_conv1d_custom -> aclnnCausalConv1d 在用它，
#      所以只改 CANN 算子类型与 ACLNN 符号，Torch 入口名和 python 调用方不动。
# =============================================================================


# 在单个文件里做一次三档大小写改名。
#
#   $1 文件
#   $2 旧小写   $3 新小写
#   $4 旧Camel  $5 新Camel
#   $6 旧大写   $7 新大写（旧大写为空则跳过）
#   $8.. 需要原样保留的同前缀符号
rename_in_file()
{
    local file="$1"
    local old_lower="$2" new_lower="$3"
    local old_camel="$4" new_camel="$5"
    local old_upper="$6" new_upper="$7"

    shift 7

    local protect=("$@")
    local expr=()
    local i=0
    local p

    # 先保护不能跟着改的同前缀符号
    for p in "${protect[@]}"; do

        [[ -z "$p" ]] && continue

        expr+=(-e "s|${p}|@@PROTECT${i}@@|g")

        i=$((i + 1))
    done

    expr+=(-e "s|${old_lower}|${new_lower}|g")

    if [[ -n "$old_camel" ]]; then
        expr+=(-e "s|${old_camel}|${new_camel}|g")
    fi

    if [[ -n "$old_upper" ]]; then
        expr+=(-e "s|${old_upper}|${new_upper}|g")
    fi

    # 还原被保护的符号
    i=0

    for p in "${protect[@]}"; do

        [[ -z "$p" ]] && continue

        expr+=(-e "s|@@PROTECT${i}@@|${p}|g")

        i=$((i + 1))
    done

    sed -i "${expr[@]}" "$file"
}


# python 侧只改自定义算子的引用，不动同名的 triton helper。
#
# 只处理这两种形态：
#
#   torch.ops._C_ascend.<算子名>
#   hasattr(..., "<算子名>")
rename_op_refs_in_python()
{
    local file="$1"
    local old_name="$2"
    local new_name="$3"

    sed -i \
        -e "s|_C_ascend\\.${old_name}|_C_ascend.${new_name}|g" \
        -e "s|\"${old_name}\"|\"${new_name}\"|g" \
        "$file"
}


# 把一个自定义算子的整条链改成独立符号：
# 目录名 + 目录内文件名 + 目录内内容 + 目录外引用。
#
#   $1 算子目录（相对 csrc/，如 moe/causal_conv1d）
#   $2 旧小写名
#   $3 旧 CamelCase 名
#   $4 旧大写名（可为空字符串）
#   $5 目录外需要整文件改名的（空格分隔，可为空）
#   $6 目录外只改算子引用的 python 文件（空格分隔，可为空）
#   $7 不能跟着改的同前缀符号（空格分隔，可为空）
rename_custom_op()
{
    local op_rel="$1"
    local old_lower="$2"
    local old_camel="$3"
    local old_upper="$4"
    local outside_all="$5"
    local outside_py="$6"
    local protect="$7"

    local new_lower="${old_lower}_vllm"
    local new_camel="${old_camel}Vllm"
    local new_upper=""

    [[ -n "$old_upper" ]] && new_upper="${old_upper}_VLLM"

    local old_dir="csrc/${op_rel}"
    local parent="${op_rel%/*}"
    local new_dir="csrc/${parent}/${new_lower}"

    local f
    local base
    local newbase


    if [[ ! -d "$old_dir" ]]; then

        echo "[rename] $old_dir 不存在，跳过。"

        return 0
    fi


    # -------------------------------------------------------------------------
    # 1. 目录改名
    # -------------------------------------------------------------------------

    git mv "$old_dir" "$new_dir"


    # -------------------------------------------------------------------------
    # 2. 目录内文件名里含旧小写名的，一并改名
    # -------------------------------------------------------------------------

    while IFS= read -r f; do

        base="$(basename "$f")"

        case "$base" in

            *"$old_lower"*)

                newbase="${base//$old_lower/$new_lower}"

                git mv "$f" "$(dirname "$f")/$newbase"
                ;;
        esac
    done < <(git ls-files "$new_dir")


    # -------------------------------------------------------------------------
    # 3. 目录内所有文件做三档改名
    # -------------------------------------------------------------------------

    while IFS= read -r f; do

        rename_in_file \
            "$f" \
            "$old_lower" "$new_lower" \
            "$old_camel" "$new_camel" \
            "$old_upper" "$new_upper" \
            $protect
    done < <(git ls-files "$new_dir")


    # -------------------------------------------------------------------------
    # 4. 目录外需要整文件改名的
    # -------------------------------------------------------------------------

    for f in $outside_all; do

        if [[ ! -f "$f" ]]; then

            echo "[ERROR] 需要改名的文件不存在："
            echo "        $f"

            return 1
        fi

        rename_in_file \
            "$f" \
            "$old_lower" "$new_lower" \
            "$old_camel" "$new_camel" \
            "$old_upper" "$new_upper" \
            $protect
    done


    # -------------------------------------------------------------------------
    # 5. 目录外只改算子引用的 python 文件
    # -------------------------------------------------------------------------

    for f in $outside_py; do

        if [[ ! -f "$f" ]]; then

            echo "[ERROR] 需要改名的 python 文件不存在："
            echo "        $f"

            return 1
        fi

        rename_op_refs_in_python "$f" "$old_lower" "$new_lower"
    done


    git add -A

    echo "[rename] ${op_rel} -> ${parent}/${new_lower}"

    return 0
}


apply_vllm_ascend_op_renames()
{
    local dir="$ROOT/vllm-ascend"


    cd "$dir"


    # 进入本函数时的 HEAD（= 9b 那个 cherry-pick 之后的 commit）。
    # 任何一项校验不过都回退到这里，绝不把半成品留给编译。
    local prev_head

    prev_head="$(git rev-parse HEAD)"


    echo
    echo "-------------------------------------------------------------------"
    echo "[rename] 给与 CANN 9.2 内置算子撞名的自定义算子换独立符号"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # 1. chunk_gated_delta_rule_fwd_h（对照上游 PR #17997 的改名部分）
    #
    #    保护 chunk_gated_delta_rule_fwd_hupdate：
    #    那是另一个 triton helper，只是名字前缀相同，不能跟着改。
    # -------------------------------------------------------------------------

    rename_custom_op \
        "moe/chunk_gated_delta_rule_fwd_h" \
        "chunk_gated_delta_rule_fwd_h" \
        "ChunkGatedDeltaRuleFwdH" \
        "CHUNK_GATED_DELTA_RULE_FWD_H" \
        "csrc/build_aclnn.sh csrc/torch_binding.cpp csrc/torch_binding_meta.cpp csrc/attention/chunk_kda_fwd/op_host/CMakeLists.txt csrc/attention/chunk_kda_fwd/op_kernel/chunk_kda_fwd_common.h csrc/attention/chunk_kda_fwd/docs/design.md" \
        "vllm_ascend/ops/triton/fla/chunk.py vllm_ascend/_310p/ops/fla/chunk_gated_delta_rule.py tests/e2e/nightly/single_node/ops/singlecard_ops/test_chunk_gated_delta_rule_fwd_h_aclnn.py tests/e2e/nightly/310p/single_node/ops/singlecard_ops/test_chunk_gated_delta_rule_fwd_h_aclnn.py tests/ut/ops/test_gdn_chunk_meta.py" \
        "chunk_gated_delta_rule_fwd_hupdate" \
        || exit 1


    # -------------------------------------------------------------------------
    # 2. causal_conv1d（上游 #17727 删除并改走 fla_npu；这里只改名）
    #
    #    保护同前缀的另一个算子和 Torch 入口名：
    #      causal_conv1d_v310 / causal_conv1d_310 / CausalConv1dV310
    #      npu_causal_conv1d_custom / npu_causal_conv1d_310
    # -------------------------------------------------------------------------

    rename_custom_op \
        "moe/causal_conv1d" \
        "causal_conv1d" \
        "CausalConv1d" \
        "CAUSAL_CONV1D" \
        "csrc/build_aclnn.sh csrc/torch_binding.cpp" \
        "" \
        "causal_conv1d_v310 causal_conv1d_310 CausalConv1dV310 CausalConv1D310 npu_causal_conv1d_custom npu_causal_conv1d_310" \
        || exit 1


    # -------------------------------------------------------------------------
    # 校验（commit 之前就能查的）：新目录在、旧名字在 csrc 里清零、
    # python 侧不再引用旧算子名。
    # -------------------------------------------------------------------------

    local stale

    if [[ ! -d csrc/moe/chunk_gated_delta_rule_fwd_h_vllm ]] || \
       [[ ! -d csrc/moe/causal_conv1d_vllm ]]; then

        echo
        echo "[ERROR] 改名后的算子目录不存在。"

        git reset --hard "$prev_head"

        exit 1
    fi


    stale="$(
        git grep \
            -n \
            -E 'chunk_gated_delta_rule_fwd_h([^u_]|$)|CHUNK_GATED_DELTA_RULE_FWD_H([^_]|$)' \
            -- csrc \
            || true
    )"

    if [[ -n "$stale" ]]; then

        echo
        echo "[ERROR] csrc 里仍有 chunk_gated_delta_rule_fwd_h 旧名："
        echo "$stale"

        git reset --hard "$prev_head"

        exit 1
    fi


    stale="$(
        git grep \
            -n \
            -E 'causal_conv1d([^_a-z0-9]|$)' \
            -- csrc \
            | grep -v 'causal_conv1d_vllm' \
            | grep -v 'causal_conv1d_v310' \
            || true
    )"

    if [[ -n "$stale" ]]; then

        echo
        echo "[ERROR] csrc 里仍有 causal_conv1d 旧名："
        echo "$stale"

        git reset --hard "$prev_head"

        exit 1
    fi


    stale="$(
        git grep \
            -n \
            -E '_C_ascend\.chunk_gated_delta_rule_fwd_h([^u_]|$)|"chunk_gated_delta_rule_fwd_h"' \
            -- vllm_ascend tests \
            || true
    )"

    if [[ -n "$stale" ]]; then

        echo
        echo "[ERROR] python 侧仍引用旧算子名："
        echo "$stale"

        git reset --hard "$prev_head"

        exit 1
    fi


    # -------------------------------------------------------------------------
    # 生成 commit。
    #
    # 和 9b 一样固定 author/committer 时间与身份，
    # 保证同一基线上重复执行得到同一个 commit SHA。
    # 必须放在"工作树干净"校验之前，否则索引里的改动会让校验必然失败。
    # -------------------------------------------------------------------------

    echo
    echo "[rename] 生成 commit"

    GIT_AUTHOR_DATE="$VLLM_ASCEND_PR_DATE" \
    GIT_COMMITTER_DATE="$VLLM_ASCEND_PR_DATE" \
    GIT_COMMITTER_NAME="$VLLM_ASCEND_PR_COMMITTER_NAME" \
    GIT_COMMITTER_EMAIL="$VLLM_ASCEND_PR_COMMITTER_EMAIL" \
    git commit \
        --quiet \
        --no-verify \
        --author="$VLLM_ASCEND_PR_AUTHOR" \
        -m "refactor(ops): give the CANN-colliding custom ops unique symbols" \
        -m "CANN 9.2 ships built-in ops_transformer kernels under
opp/built-in/op_impl/ai_core/tbe/kernel/<soc>/ops_transformer/<op>_apt.
The OPC tool compares every custom operator against the same-named built-in
entry in the op store and fails when the ABI differs:

  CausalConv1d            invalid input nums[8], should equal 12 in op store
  ChunkGatedDeltaRuleFwdH op_info_parser crashed on a None attribute

kda_gate_cumsum has the same problem and is handled by the preceding commit.
The built-ins cannot be removed, so the custom operators get their own
symbols instead:

  moe/chunk_gated_delta_rule_fwd_h -> moe/chunk_gated_delta_rule_fwd_h_vllm
    Mirrors upstream #17997 (identifier/case rename only). That PR also
    switched the python path from fla_npu back to the in-tree operator; this
    baseline predates #17727 and already calls the in-tree operator, so that
    part does not apply and is not taken.

  moe/causal_conv1d -> moe/causal_conv1d_vllm
    Upstream #17727 deleted this operator and moved to fla_npu. This baseline
    still uses it through torch.ops._C_ascend.npu_causal_conv1d_custom ->
    aclnnCausalConv1d, so only the CANN operator type and the ACLNN symbols
    are renamed; the Torch entry point and all python callers stay unchanged.

No computation logic is touched. This commit is generated by
afd_build_and_compile.sh with a fixed commit date and committer so its SHA is
stable and the build stamp cache keeps working."


    # -------------------------------------------------------------------------
    # commit 之后的校验：工作树必须干净。
    # 后面的 afd-plugin 安装校验依赖这一点。
    # -------------------------------------------------------------------------

    if [[ -n "$(
        git status --porcelain
    )" ]]; then

        echo
        echo "[ERROR] 改名后工作树不干净："

        git status --short

        git reset --hard "$prev_head"

        exit 1
    fi


    echo
    echo "[rename] 完成，HEAD:"

    git log \
        --oneline \
        -1

    echo
}


# =============================================================================
# 10. Clone afd-plugin
#
# afd-plugin：
#
#   正常 git clone
#
# 不使用：
#
#   --depth
#   --single-branch
#
#
# 即正常下载完整仓库。
#
#
# clone 完以后：
#
#   checkout main
#
# 仓库已存在：
#
#   fetch origin
#       ↓
#   checkout main
#       ↓
#   pull --ff-only origin main
#
# =============================================================================

clone_afd_plugin()
{
    local dir="$ROOT/afd-plugin"


    echo
    echo "-------------------------------------------------------------------"
    echo "[repo] afd-plugin"
    echo "[repo] URL    : $AFD_PLUGIN_URL"
    echo "[repo] branch : $AFD_PLUGIN_BRANCH"
    echo "[repo] clone  : normal full git clone"
    echo "-------------------------------------------------------------------"


    # -------------------------------------------------------------------------
    # --force
    # -------------------------------------------------------------------------

    if [[ "$FORCE" -eq 1 && -d "$dir" ]]; then

        echo "[clone] --force: removing old afd-plugin"
        echo "        $dir"

        rm -rf "$dir"

    fi


    # -------------------------------------------------------------------------
    # 第一次：
    #
    # 正常完整 clone。
    # -------------------------------------------------------------------------

    if [[ ! -d "$dir/.git" ]]; then

        echo
        echo "[clone] Normal cloning afd-plugin."
        echo "[clone] Full repository/history will be downloaded."
        echo


        git clone \
            "$AFD_PLUGIN_URL" \
            "$dir"


    else

        echo
        echo "[clone] afd-plugin already exists."
        echo "[clone] Skip clone."


        # ---------------------------------------------------------------------
        # 如果之前是 shallow clone，
        #
        # 转成完整仓库。
        # ---------------------------------------------------------------------

        if [[ "$(
            git -C "$dir" rev-parse --is-shallow-repository
        )" == "true" ]]; then

            echo
            echo "[git] Existing afd-plugin repository is shallow."
            echo "[git] Converting it to full repository..."


            git -C "$dir" fetch \
                --unshallow \
                origin

        else

            echo
            echo "[git] Fetching latest remote refs..."

            git -C "$dir" fetch \
                origin \
                --tags

        fi

    fi


    # -------------------------------------------------------------------------
    # checkout main
    # -------------------------------------------------------------------------

    echo
    echo "[git] Checkout afd-plugin branch:"
    echo "      $AFD_PLUGIN_BRANCH"


    # 本地没有 main 时，基于 origin/main 创建。
    if git -C "$dir" show-ref \
        --verify \
        --quiet \
        "refs/heads/$AFD_PLUGIN_BRANCH"; then


        git -C "$dir" checkout \
            "$AFD_PLUGIN_BRANCH"


    else

        git -C "$dir" checkout \
            -b "$AFD_PLUGIN_BRANCH" \
            "origin/$AFD_PLUGIN_BRANCH"

    fi


    # -------------------------------------------------------------------------
    # 只允许 fast-forward。
    #
    # 如果本地 main 出现自己额外的 commit，
    # 不允许脚本自动 merge。
    # -------------------------------------------------------------------------

    git -C "$dir" pull \
        --ff-only \
        origin \
        "$AFD_PLUGIN_BRANCH"


    echo
    echo "[git] afd-plugin HEAD:"

    git -C "$dir" log \
        --oneline \
        -1


    echo
}


# =============================================================================
# 11. Clone / Checkout / cherry-pick
# =============================================================================

step "1/5 clone + checkout + vLLM-Ascend cherry-pick"


clone_vllm

clone_vllm_ascend

apply_vllm_ascend_pr_17998

apply_vllm_ascend_op_renames

clone_afd_plugin


# =============================================================================
# 12. Repository Summary
# =============================================================================

echo
echo "==================================================================="
echo "Repository summary"
echo "==================================================================="


echo
echo "[vllm]"
git -C "$ROOT/vllm" log \
    --oneline \
    -1


echo
echo "[vllm-ascend]"
echo "  base commit : $VLLM_ASCEND_COMMIT"
echo "  cherry-pick : PR #$VLLM_ASCEND_PR_NUMBER"
echo "  renames     : chunk_gated_delta_rule_fwd_h / causal_conv1d"
git -C "$ROOT/vllm-ascend" log \
    --oneline \
    -1


echo
echo "[afd-plugin]"
git -C "$ROOT/afd-plugin" log \
    --oneline \
    -1


echo


# =============================================================================
# 13. Build Stamp
#
# need_build：
#
#   return 0
#     → 需要 build
#
#   return 1
#     → 已经 build，可以 skip
#
#
# 判断：
#
#   当前 Git HEAD
#
#       VS
#
#   stamp 中保存的 HEAD
#
# =============================================================================

need_build()
{
    local repo="$1"
    local stamp="$2"

    local current_head


    current_head="$(
        git -C "$repo" rev-parse HEAD
    )"


    # --force 永远重新 build
    if [[ "$FORCE" -eq 1 ]]; then
        return 0
    fi


    # stamp 不存在：
    #
    # 说明还没成功 build 过。
    if [[ ! -f "$stamp" ]]; then
        return 0
    fi


    local built_head

    built_head="$(
        cat "$stamp"
    )"


    # Git HEAD 发生变化。
    if [[ "$current_head" != "$built_head" ]]; then
        return 0
    fi


    # HEAD 相同：
    #
    # 已经 build。
    return 1
}


write_stamp()
{
    local repo="$1"
    local stamp="$2"


    # build 成功以后调用。
    #
    # 保存当前 Git HEAD。
    git -C "$repo" \
        rev-parse HEAD \
        > "$stamp"
}


# =============================================================================
# 14. Build dependencies
# =============================================================================

echo
echo "[pip] Installing build dependencies..."


python3 -m pip install \
    setuptools-rust


# =============================================================================
# 15. Build vLLM
# =============================================================================

step "2/5 编译安装 vLLM empty"


VLLM_DIR="$ROOT/vllm"

VLLM_STAMP="$STAMP_DIR/vllm"


cd "$VLLM_DIR"


# -----------------------------------------------------------------------------
# 使用基础镜像已有的 torch。
#
# 防止构建 vLLM 时重新拉取 stock torch。
# -----------------------------------------------------------------------------

if [[ -f use_existing_torch.py ]]; then

    echo "[vllm] Reusing existing torch stack..."

    python3 use_existing_torch.py

else

    echo "[ERROR] use_existing_torch.py not found:"
    echo "        $VLLM_DIR/use_existing_torch.py"

    exit 1

fi


# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if need_build \
    "$VLLM_DIR" \
    "$VLLM_STAMP"; then


    echo
    echo "[vllm] Building..."
    echo "[vllm] ref=$VLLM_REF"
    echo "[vllm] VLLM_TARGET_DEVICE=empty"
    echo


    VLLM_TARGET_DEVICE=empty \
    SETUPTOOLS_SCM_PRETEND_VERSION=0.30.0 \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$VLLM_DIR" \
        "$VLLM_STAMP"


else

    echo
    echo "[vllm] Current Git HEAD has already been built."
    echo "[vllm] Skip build."

fi


# -----------------------------------------------------------------------------
# vLLM 安装过程可能修改 numpy / fastapi。
#
# 恢复 Ascend 环境版本。
# -----------------------------------------------------------------------------

echo
echo "[vllm] Restoring numpy / fastapi..."


python3 -m pip install \
    "numpy==1.26.4" \
    "fastapi<0.124.0"


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
from importlib.metadata import version

# 此时 Ascend 尚未构建；import vllm 会自动加载已注册的 Ascend 插件，
# 可能访问重新 clone 后尚未生成的 _build_info.py。这里只检查安装元数据。
print("[vllm] installed version =", version("vllm"))
print("[vllm] full import check deferred until the complete stack is installed")
PY


# =============================================================================
# 16. Build vLLM-Ascend
# =============================================================================

step "3/5 编译安装 vLLM-Ascend"


VLLM_ASCEND_DIR="$ROOT/vllm-ascend"

VLLM_ASCEND_STAMP="$STAMP_DIR/vllm-ascend"


cd "$VLLM_ASCEND_DIR"


# -----------------------------------------------------------------------------
# torch_npu 检查
# -----------------------------------------------------------------------------

python3 - <<'PY'
import torch
import torch_npu

print("[vllm-ascend] torch_npu OK")

print(
    "[vllm-ascend] device =",
    torch.npu.get_device_name(0)
)
PY


# 某些基础镜像设置的 LD_PRELOAD
# 可能影响源码编译。
unset LD_PRELOAD || true


# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

if need_build \
    "$VLLM_ASCEND_DIR" \
    "$VLLM_ASCEND_STAMP"; then


    echo
    echo "[vllm-ascend] Building..."
    echo "[vllm-ascend] base commit=$VLLM_ASCEND_COMMIT"
    echo "[vllm-ascend] cherry-pick=PR #$VLLM_ASCEND_PR_NUMBER"
    echo "[vllm-ascend] renames=chunk_gated_delta_rule_fwd_h / causal_conv1d"
    echo "[vllm-ascend] SOC_VERSION=$SOC_VERSION"
    echo


    # -------------------------------------------------------------------------
    # 清理算子构建目录。
    #
    # build_aclnn.sh 只清 output/build_out，故意保留 csrc/build。
    # 但算子目录改过名（第 9c 节）之后，保留下来的 csrc/build 里还带着
    # 改名前的算子目录与目标文件，配置生成会因此失败：
    #
    #   [ERROR] op <改名前的算子名>: not any obj compile success
    #   FAILED: CMakeFiles/ops_config_<soc> ...
    #
    # 所以只要真的在重建 vllm-ascend，就先清掉它，做一次干净构建。
    # HEAD 没变时走的是 skip 分支，不受影响。
    # -------------------------------------------------------------------------

    if [[ -d "$VLLM_ASCEND_DIR/csrc/build" ]]; then

        echo "[vllm-ascend] 清理 csrc/build，避免改名前残留的算子构建状态"

        rm -rf "$VLLM_ASCEND_DIR/csrc/build"
    fi


    SOC_VERSION="$SOC_VERSION" \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$VLLM_ASCEND_DIR" \
        "$VLLM_ASCEND_STAMP"


else

    echo
    echo "[vllm-ascend] Current Git HEAD has already been built."
    echo "[vllm-ascend] Skip build."

fi


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
import vllm_ascend

print("[vllm-ascend] import OK")

print(
    "[vllm-ascend] version =",
    getattr(vllm_ascend, "__version__", "unknown")
)
PY


# =============================================================================
# 17. Build afd-plugin
# =============================================================================

step "4/5 编译安装 afd-plugin"


AFD_PLUGIN_DIR="$ROOT/afd-plugin"

AFD_PLUGIN_STAMP="$STAMP_DIR/afd-plugin"


cd "$AFD_PLUGIN_DIR"


# AFD 必须通过 Python 插件机制接入，不得修改 vLLM 或 vLLM-Ascend 的
# 已跟踪源码。记录安装前状态，安装完成后做严格对比。
VLLM_TREE_BEFORE="$(
    git -C "$VLLM_DIR" status --porcelain --untracked-files=no
)"

VLLM_ASCEND_TREE_BEFORE="$(
    git -C "$VLLM_ASCEND_DIR" status --porcelain --untracked-files=no
)"


if need_build \
    "$AFD_PLUGIN_DIR" \
    "$AFD_PLUGIN_STAMP"; then


    echo
    echo "[afd-plugin] Building..."
    echo "[afd-plugin] branch=$AFD_PLUGIN_BRANCH"
    echo "[afd-plugin] SOC_VERSION=$SOC_VERSION"
    echo


    SOC_VERSION="$SOC_VERSION" \
    python3 -m pip install \
        -e . \
        --no-build-isolation


    write_stamp \
        "$AFD_PLUGIN_DIR" \
        "$AFD_PLUGIN_STAMP"


else

    echo
    echo "[afd-plugin] Current Git HEAD has already been built."
    echo "[afd-plugin] Skip build."

fi


VLLM_TREE_AFTER="$(
    git -C "$VLLM_DIR" status --porcelain --untracked-files=no
)"

VLLM_ASCEND_TREE_AFTER="$(
    git -C "$VLLM_ASCEND_DIR" status --porcelain --untracked-files=no
)"

if [[ "$VLLM_TREE_AFTER" != "$VLLM_TREE_BEFORE" ]]; then
    echo "[ERROR] afd-plugin installation modified tracked vLLM source files."
    git -C "$VLLM_DIR" status --short
    exit 1
fi

if [[ "$VLLM_ASCEND_TREE_AFTER" != "$VLLM_ASCEND_TREE_BEFORE" ]]; then
    echo "[ERROR] afd-plugin installation modified tracked vLLM-Ascend source files."
    git -C "$VLLM_ASCEND_DIR" status --short
    exit 1
fi

echo "[afd-plugin] Verified: vLLM source trees were not modified."


# -----------------------------------------------------------------------------
# Verify
# -----------------------------------------------------------------------------

python3 - <<'PY'
from importlib.metadata import entry_points

import afd_plugin

print("[afd-plugin] import OK")

print(
    "[afd-plugin] version =",
    getattr(afd_plugin, "__version__", "unknown")
)

plugins = {
    ep.name: ep.value
    for ep in entry_points(group="vllm.general_plugins")
}

actual = plugins.get("afd")
expected = "afd_plugin:register_afd"

if actual != expected:
    raise RuntimeError(
        "AFD vllm.general_plugins entry point mismatch: "
        f"expected={expected!r}, actual={actual!r}"
    )

print("[afd-plugin] entry point =", f"afd -> {actual}")
PY


# =============================================================================
# 18. 最终验证
# =============================================================================

step "5/5 验证完整 AFD 环境"


# -----------------------------------------------------------------------------
# Git HEAD
# -----------------------------------------------------------------------------

echo "---------------- Git HEAD ----------------"
echo


printf "%-18s " "vllm:"

git -C "$ROOT/vllm" \
    rev-parse \
    --short HEAD


printf "%-18s " "vllm-ascend:"

git -C "$ROOT/vllm-ascend" \
    rev-parse \
    --short HEAD

echo "                   (base $VLLM_ASCEND_COMMIT + PR #$VLLM_ASCEND_PR_NUMBER + 2 个改名)"


printf "%-18s " "afd-plugin:"

git -C "$ROOT/afd-plugin" \
    rev-parse \
    --short HEAD


# -----------------------------------------------------------------------------
# Python packages
# -----------------------------------------------------------------------------

echo
echo "---------------- Python packages ----------------"
echo


python3 -m pip show \
    vllm \
    vllm-ascend \
    vllm-afd-plugin \
    torch \
    torch-npu \
    triton-ascend \
    2>/dev/null \
    | grep -E \
        "^(Name|Version|Editable project location):" \
    || true


# -----------------------------------------------------------------------------
# Import check
# -----------------------------------------------------------------------------

echo
echo "---------------- Import check ----------------"
echo


python3 - <<'PY'
import torch
import torch_npu
import vllm
import vllm_ascend
import afd_plugin

print(
    "torch       :",
    torch.__version__
)

print(
    "torch_npu   :",
    torch_npu.__version__
)

print(
    "vllm        :",
    getattr(vllm, "__version__", "unknown")
)

print(
    "vllm_ascend :",
    getattr(vllm_ascend, "__version__", "unknown")
)

print(
    "afd_plugin  :",
    getattr(afd_plugin, "__version__", "unknown")
)

print()

print(
    "NPU         :",
    torch.npu.get_device_name(0)
)
PY


# -----------------------------------------------------------------------------
# AFD custom ops
# -----------------------------------------------------------------------------

echo
echo "---------------- AFD ops ----------------"
echo


cd "$AFD_PLUGIN_DIR"


python3 - <<'PY'
import torch
import torch_npu

from afd_plugin.compat.npu import ensure_afd_ascend_ops_loaded

ensure_afd_ascend_ops_loaded()

print("AFD_OPS_OK")
PY


# -----------------------------------------------------------------------------
# a2e / e2a 编译产物
# -----------------------------------------------------------------------------

echo
echo "---------------- AFD custom-op artifacts ----------------"
echo


AFD_OP_ROOT="afd_plugin/_cann_ops_custom/vendors/afd-plugin"


if [[ -f "$AFD_OP_ROOT/op_api/lib/libcust_opapi.so" ]]; then

    echo "[OK] libcust_opapi.so"

else

    echo "[WARN] libcust_opapi.so not found"

fi


for op in a2e e2a; do

    OP_DIR="$AFD_OP_ROOT/op_impl/ai_core/tbe/kernel/ascend950/$op"


    if [[ -d "$OP_DIR" ]] && \
       find "$OP_DIR" \
           -mindepth 1 \
           -print \
           -quit \
           2>/dev/null \
       | grep -q .; then

        echo "[OK] ascend950/$op"

    else

        echo "[WARN] ascend950/$op kernel not found"

    fi

done


# =============================================================================
# 19. 完成
# =============================================================================

echo
echo "==================================================================="
echo "AFD build completed"
echo "==================================================================="


echo
echo "Source root:"
echo "  $ROOT"


echo
echo "SOC_VERSION:"
echo "  $SOC_VERSION"


echo
echo "Clone strategy:"


echo
echo "  vllm:"
echo "    ref   = $VLLM_REF"
echo "    commit= $VLLM_COMMIT"
echo "    depth = 1"
echo "    only v0.30.0 is downloaded"


echo
echo "  vllm-ascend:"
echo "    clone       = normal full git clone"
echo "    base commit = $VLLM_ASCEND_COMMIT"
echo "    cherry-pick = PR #$VLLM_ASCEND_PR_NUMBER"
echo "                  $VLLM_ASCEND_PR_COMMIT"
echo "                  (kda_gate_cumsum -> kda_gate_cumsum_vllm)"
echo "    renames     = chunk_gated_delta_rule_fwd_h -> chunk_gated_delta_rule_fwd_h_vllm"
echo "                  causal_conv1d -> causal_conv1d_vllm"


echo
echo "  afd-plugin:"
echo "    clone  = normal full git clone"
echo "    branch = $AFD_PLUGIN_BRANCH"


echo
echo "Build log:"
echo "  $LOG"


echo
echo "Build stamps:"
echo "  $STAMP_DIR"


echo
echo "==================================================================="
