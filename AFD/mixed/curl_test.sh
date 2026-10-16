#!/usr/bin/env bash
# Smoke-test the mixed (non-disaggregated) deployment.
#
#   bash curl_test.sh                      # 默认 18000 / deepseek-v4
#   bash curl_test.sh 18000 deepseek-v4
#   PORT=18000 HOST_IP=127.0.0.1 bash curl_test.sh
#
# 只做连通性检查，不代表精度或性能达标。要做完整校验（JSON 解析、状态码、
# finish_reason、usage）用仓库根目录的 test_openai_api.sh。
set -euo pipefail

HOST_IP="${HOST_IP:-127.0.0.1}"
PORT="${1:-${PORT:-18000}}"
MODEL="${2:-deepseek-v4}"
TIMEOUT="${TIMEOUT:-120}"
BASE_URL="http://${HOST_IP}:${PORT}/v1"

command -v curl >/dev/null 2>&1 || { echo '[ERROR] 未找到 curl' >&2; exit 1; }

# curl 用系统库搜索路径；Ascend 容器里预置的 LD_LIBRARY_PATH 会干扰。
curl_api() {
    local method="$1" path="$2" data="${3:-}" auth=()
    [[ -z "${OPENAI_API_KEY:-}" ]] || auth=(-H "Authorization: Bearer ${OPENAI_API_KEY}")
    local args=(--silent --show-error --noproxy "${HOST_IP}"
        --connect-timeout 10 --max-time "${TIMEOUT}"
        -X "${method}" -H 'Content-Type: application/json')
    [[ -z "${data}" ]] || args+=(--data-binary "${data}")
    env -u LD_LIBRARY_PATH -u LD_PRELOAD curl "${args[@]}" "${auth[@]}" "${BASE_URL}${path}"
}

echo "[curl] ${BASE_URL}"

echo '--- GET /v1/models'
MODELS="$(curl_api GET /models)" || { echo '[FAIL] /v1/models 请求失败；服务没起或端口不对。' >&2; exit 1; }
printf '%s\n' "${MODELS}"
case "${MODELS}" in
    *"\"${MODEL}\""*) echo "[PASS] /v1/models 列出了 ${MODEL}" ;;
    *) echo "[FAIL] /v1/models 里没有 ${MODEL}" >&2; exit 1 ;;
esac

echo '--- POST /v1/chat/completions'
# 提示词内不要带双引号；这个脚本不引 JSON 库，从宽处理。
BODY="{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"你好，请用一句话介绍一下自己。\"}],\"max_tokens\":128,\"stream\":false}"
RESP="$(curl_api POST /chat/completions "${BODY}")" || { echo '[FAIL] /v1/chat/completions 请求失败。' >&2; exit 1; }
printf '%s\n' "${RESP}"
case "${RESP}" in
    *'"content"'*|*'"reasoning_content"'*) echo '[PASS] 响应里有回答内容' ;;
    *) echo '[FAIL] 响应里既没有 content 也没有 reasoning_content' >&2; exit 1 ;;
esac

echo "[PASS] 混布接口连通（不代表精度或性能达标）"