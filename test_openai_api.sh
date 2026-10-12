#!/usr/bin/env bash
set -euo pipefail

# OpenAI 兼容接口连通性测试，不是性能压测。
# bash test_openai_api.sh                       # 交互输入端口，无默认端口
# bash test_openai_api.sh 18000                 # 自动读取服务的第一个模型名
# bash test_openai_api.sh 18000 deepseek-v4 '你好，请介绍一下自己'
# AFD 必须填写 Attention 的 API 端口，不是 FFN / connector 端口。
# 可选环境变量：HOST_IP（默认 127.0.0.1）、OPENAI_API_KEY、PYTHON。
# 接口参考：https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

if [[ $# -gt 3 ]]; then
    echo "用法：bash $0 [端口] [模型名] [测试问题]" >&2
    exit 2
fi

PORT="${1:-}"
MODEL="${2:-}"
PROMPT="${3:-你好，请用一句话介绍一下自己。}"
HOST_IP="${HOST_IP:-127.0.0.1}"
PYTHON="${PYTHON:-python3}"

if [[ -z "$PORT" ]]; then
    read -r -p '请输入服务端口（AFD 填 Attention 端口）: ' PORT || {
        echo '[ERROR] 必须输入服务端口。' >&2
        exit 2
    }
fi
PORT="${PORT%$'\r'}"
if [[ ! "$PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
    echo '[ERROR] 端口必须是 1～65535 的整数。' >&2
    exit 2
fi
PORT=$((10#$PORT))

for tool in curl "$PYTHON"; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "[ERROR] 未找到命令：$tool" >&2
        exit 1
    }
done

BASE_URL="http://${HOST_IP}:${PORT}/v1"
HEADERS=(-H 'Content-Type: application/json')
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    HEADERS+=(-H "Authorization: Bearer $OPENAI_API_KEY")
fi

request()
{
    local method="$1" endpoint="$2" response status
    local args=()
    [[ "$method" != POST ]] || args=(--data-binary "$3")
    # curl 使用系统库搜索路径；Python 仅处理 JSON，不导入 ssl 或安装 SDK。
    if ! response="$(env -u LD_LIBRARY_PATH -u LD_PRELOAD curl \
        --silent --show-error --noproxy "$HOST_IP" \
        --connect-timeout 10 --max-time 120 \
        -X "$method" "${HEADERS[@]}" "${args[@]}" \
        -w $'\n%{http_code}' "${BASE_URL}${endpoint}")"; then
        echo "[ERROR] 请求失败：${BASE_URL}${endpoint}，请检查服务和端口。" >&2
        return 1
    fi
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
        printf '[ERROR] HTTP %s\n%s\n' "$status" "$response" >&2
        return 1
    fi
    printf '%s' "$response"
}

echo "[OpenAI] 测试地址：$BASE_URL"
MODELS_JSON="$(request GET /models)"
MODEL="$(printf '%s' "$MODELS_JSON" | "$PYTHON" -c '
import json, sys
try:
    ids = [item["id"] for item in json.load(sys.stdin)["data"]]
    model = sys.argv[1] or ids[0]
    if not isinstance(model, str) or not model or model not in ids:
        raise ValueError("模型名不在 /v1/models 列表中：" + str(ids))
    print(model)
except (ValueError, KeyError, IndexError, TypeError) as exc:
    sys.exit("[ERROR] 模型列表无效：" + str(exc))
' "$MODEL")"
echo "[OpenAI] 模型：$MODEL"
echo "[OpenAI] 问题：$PROMPT"

PAYLOAD="$("$PYTHON" - "$MODEL" "$PROMPT" <<'PY'
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 512,
    "stream": False,
}, ensure_ascii=True))
PY
)"
CHAT_JSON="$(request POST /chat/completions "$PAYLOAD")"
printf '%s' "$CHAT_JSON" | "$PYTHON" -c '
import json, sys
try:
    data = json.load(sys.stdin)
    choice = data["choices"][0]
    message = choice["message"]
    content = message.get("content")
    reasoning = message.get("reasoning_content") or message.get("reasoning")
    if not content and not reasoning:
        raise ValueError("响应没有回答或推理内容：" + json.dumps(data, ensure_ascii=False))
    print("[OpenAI] 回复：\n" + str(content or reasoning))
    if not content:
        print("[WARN] 仅收到推理内容，没有最终回答；可能已达到输出长度限制。")
    print("[OpenAI] finish_reason =", choice.get("finish_reason"))
    print("[OpenAI] usage =", json.dumps(data.get("usage"), ensure_ascii=False))
    print("[PASS] 模型列表和聊天接口均成功返回内容（不代表精度或性能达标）。")
except (ValueError, KeyError, IndexError, TypeError, AttributeError) as exc:
    sys.exit("[ERROR] 聊天响应无效：" + str(exc))
'
