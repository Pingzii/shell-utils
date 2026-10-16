#!/usr/bin/env bash
# Mixed (non-disaggregated) deployment: every card runs the whole model and there
# is no AFD connector. This is the baseline the 2A2F / 4A2F / 6A2F / 4A4F splits
# are compared against.
#
#   bash serve_mix.sh
#
# Extra arguments are forwarded to `vllm serve`, so a one-off override needs no edit:
#   bash serve_mix.sh --kv-cache-dtype fp8
#   bash serve_mix.sh --attention-config '{"indexer_kv_dtype": "int8"}'
#
# 改卡只要改 ATTN_DEVICES；--data-parallel-size 由它算出来。
set -euo pipefail

MODEL_PATH="/mnt/share/weight/DeepSeek-V4-Flash"
SERVED_MODEL_NAME="deepseek-v4"

# 本机仅卡 0/卡 1 可开 TSD，卡 2/4/5 报 E30009 签名失败，所以这一档用 2,3,4,5。
ATTN_DEVICES="2,3,4,5"
# 混布没有独立的 FFN 角色；保留这一行只为跟 A/F 脚本对照日志。
FFN_DEVICES="6,7"
ATTN_PORT="18000"
FFN_PORT="18010"
MAX_MODEL_LEN="4096"

export ASCEND_RT_VISIBLE_DEVICES="$ATTN_DEVICES"
export PYTHONUNBUFFERED="1"
export VLLM_USE_V1=1
export HCCL_BUFFSIZE=2048
# 950 坑：AIV 向量核算子(all_gather 等)触发 vector core 异常 507035，规避用非 AIV 路径
# 950 坑修复：不设 HCCL_OP_EXPANSION_MODE（默认 iamg tiling，避开 AIV 向量核算子 507035）。DIRECT/AIV 均会触发问题
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:False

# 卡数就是 DP 大小，从 ATTN_DEVICES 推，免得两处改漏一处。
DP_SIZE="$(awk -F, '{print NF}' <<< "$ATTN_DEVICES")"
# Without an explicit block size the platform resolves it from the backend list
# (up to 4096) and the DeepSeek V4 block-size table raises KeyError: 4096.
KV_BLOCK_SIZE=32

exec vllm serve "$MODEL_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --data-parallel-size "$DP_SIZE" \
    --tensor-parallel-size 1 \
    --enable-expert-parallel \
    --compilation-config '{"cudagraph_capture_sizes":[32,64,128,256], "cudagraph_mode": "FULL_DECODE_ONLY"}' \
    --host 127.0.0.1 \
    --port "$ATTN_PORT" \
    --block-size "$KV_BLOCK_SIZE" \
    --max-model-len "$MAX_MODEL_LEN" \
    --trust-remote-code \
    "$@"