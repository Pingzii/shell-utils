#!/usr/bin/env bash
# AFD Attention role - 4A2F topology (4 attention ranks + 2 FFN ranks)
#
# Extra arguments are forwarded to `vllm serve`, so a one-off override needs no edit:
#   bash afd_serve_A.sh --kv-cache-dtype fp8
#   bash afd_serve_A.sh --attention-config '{"indexer_kv_dtype": "int8"}'
set -euo pipefail

MODEL_PATH="/mnt/weight/A5-weights/DeepSeek-V4-Flash"
SERVED_MODEL_NAME="DeepSeek-V4-Flash"
ATTN_DEVICES="0,1,2,3"
FFN_DEVICES="4,5"
ATTN_PORT="18000"
FFN_PORT="18010"
AFD_HOST="127.0.0.1"
AFD_PORT="6239"
MAX_MODEL_LEN=3000
MAX_NUM_SEQS=256
# Without an explicit block size the platform resolves it from the backend list
# (up to 4096) and the DeepSeek V4 block-size table raises KeyError: 4096.
KV_BLOCK_SIZE=32
ATTN_RANKS=4
FFN_RANKS=2

export ASCEND_RT_VISIBLE_DEVICES="$ATTN_DEVICES"
export VLLM_PLUGINS="ascend,afd"
export PYTHONUNBUFFERED="1"
export VLLM_USE_V1=1
export HCCL_BUFFSIZE=2048
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:False
export AFD_NPU_CAMP2P_QUANT_MODE=4

AFD_CONFIG="$(printf '{"afd":{"role":"attention","connector":"CAMP2pAFDConnector","host":"%s","port":%s,"num_attention_ranks":%s,"num_ffn_ranks":%s}}' \
    "$AFD_HOST" "$AFD_PORT" "$ATTN_RANKS" "$FFN_RANKS")"

exec vllm serve "$MODEL_PATH" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --data-parallel-size 4 \
    --tensor-parallel-size 1 \
    --enable-expert-parallel \
    --compilation-config '{"cudagraph_capture_sizes":[32,64,128,256], "cudagraph_mode": "FULL_DECODE_ONLY"}' \
    --host 127.0.0.1 \
    --port "$ATTN_PORT" \
    --block-size "$KV_BLOCK_SIZE" \
    --max-model-len "$MAX_MODEL_LEN" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --trust-remote-code \
    --kv-cache-dtype fp8 \
    --attention-config '{"indexer_kv_dtype":"fp8"}' \
    --profiler-config '{"profiler": "torch", "torch_profiler_dir": "./vllm_profile", "torch_profiler_with_stack": false}' \
    --additional-config "$AFD_CONFIG" \
    "$@"