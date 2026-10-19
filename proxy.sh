#!/usr/bin/env bash
# 用法：source ./proxy.sh（不要 bash proxy.sh，否则变量无法保留）。
# 默认代理 141.2.191.233:8080；IP 变化时可先 export PROXY_IP=新IP。
# 用户名默认 p_atlas；密码隐藏输入，也可由 PROXY_PASSWORD 环境变量提供。
# 再次 source 时复用当前终端中的认证信息，不需要重复输入。
# 不启用 set -euo pipefail，避免改变调用者的 Shell 行为。

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo '请使用：source ./proxy.sh' >&2
    exit 2
fi

# 调用者即使开启了 set -x，也不在本脚本中跟踪打印凭据。
_afd_proxy_trace=0
if [[ "$-" == *x* ]]; then
    set +x
    _afd_proxy_trace=1
fi

# 保留此独立 export 行，兼容 create_container.sh 对 proxy.sh 的 IP 同步。
export ip_addr="${PROXY_IP:-141.2.191.233}"

_afd_proxy_encode()
{
    local LC_ALL=C value="$1" result='' char hex index
    for ((index=0; index<${#value}; index++)); do
        char="${value:index:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) result+="$char" ;;
            *) printf -v hex '%%%02X' "'$char"; result+="$hex" ;;
        esac
    done
    printf '%s' "$result"
}

_afd_proxy_setup()
{
    local port="${PROXY_PORT:-8080}" user="${PROXY_USER:-p_atlas}"
    local password='' auth='' existing="${http_proxy:-${HTTP_PROXY:-}}"
    local insecure="${PROXY_INSECURE_SSL:-0}" encoded_user tool
    for tool in git pip3; do
        command -v "$tool" >/dev/null 2>&1 || {
            echo "[ERROR] 未找到 $tool，请先安装。" >&2
            return 1
        }
    done
    if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        echo '[ERROR] PROXY_PORT 必须是 1～65535。' >&2
        return 1
    fi
    [[ "$insecure" == 0 || "$insecure" == 1 ]] || {
        echo '[ERROR] PROXY_INSECURE_SSL 只能是 0 或 1。' >&2
        return 1
    }
    port=$((10#$port))
    encoded_user="$(_afd_proxy_encode "$user")" || return 1

    # 只复用含 username:password 的 HTTP 代理；不接受缺少冒号的旧错误格式。
    if [[ -z "${PROXY_PASSWORD+x}" && "$existing" == http://*:*@* ]]; then
        auth="${existing#http://}"
        auth="${auth%@*}"
        if [[ "${auth%%:*}" != "$encoded_user" || "$auth" == *@* || -z "${auth#*:}" ]]; then
            auth=''
        fi
    fi
    if [[ -z "$auth" ]]; then
        if [[ -n "${PROXY_PASSWORD+x}" ]]; then
            password="$PROXY_PASSWORD"
        elif [[ -t 0 ]]; then
            read -r -s -p "请输入代理密码（用户 $user）: " password || return 1
            printf '\n'
        else
            echo '[ERROR] 非交互环境请先设置 PROXY_PASSWORD，或在交互终端首次 source。' >&2
            return 1
        fi
        [[ -n "$password" ]] || { echo '[ERROR] 代理密码不能为空。' >&2; return 1; }
        auth="${encoded_user}:$(_afd_proxy_encode "$password")" || return 1
    fi

    # Shell 代理：保留 ip_addr 命名，兼容既有脚本；认证信息正确做 URL 编码。
    export http_proxy="http://${auth}@${ip_addr}:${port}"
    export https_proxy="$http_proxy"
    export no_proxy="${PROXY_NO_PROXY:-127.0.0.1,localhost,local,.local}"
    export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
    unset PROXY_PASSWORD

    # pip 下载源：沿用现有 HTTP 阿里云镜像，不把代理密码另存到 pip 配置。
    # HTTP/trusted-host 降低传输安全性；可验证证书时应改为 HTTPS 镜像。
    pip3 config --user set global.index-url 'http://mirrors.aliyun.com/pypi/simple/' || return 1
    pip3 config --user set global.trusted-host 'mirrors.aliyun.com' || return 1
    export PIP_INDEX_URL='http://mirrors.aliyun.com/pypi/simple/'
    export PIP_TRUSTED_HOST='mirrors.aliyun.com'
    export PIP_PROXY="$http_proxy"

    # 仅修复全局作用域的重复项；不擅自修改系统级、仓库级或 include 文件。
    git config --global --replace-all http.proxy "$http_proxy" || return 1
    git config --global --replace-all https.proxy "$https_proxy" || return 1

    # 默认恢复证书验证；内部 CA 应通过 http.sslCAInfo 等方式配置。
    if [[ "$insecure" == 1 ]]; then
        git config --global --replace-all http.sslVerify false || return 1
        export GIT_SSL_NO_VERIFY=1
        echo '[WARN] 已显式关闭 Git TLS 证书验证，存在中间人攻击风险。'
    else
        git config --global --replace-all http.sslVerify true || return 1
        unset GIT_SSL_NO_VERIFY
    fi

    echo '========== Proxy Setup Complete =========='
    echo "Proxy: ${ip_addr}:${port}（认证信息不打印）"
    echo "pip index: $PIP_INDEX_URL"
    echo "Git TLS verify: $([[ "$insecure" == 1 ]] && echo false || echo true)（全局配置）"
    echo '[INFO] 配置已写入，不代表代理链路可用；请先检查宿主机 IPOP。'
    echo '[WARN] 认证信息保存在代理环境变量及 Git 全局配置中，请勿分享完整配置或调试日志。'
}

if _afd_proxy_setup; then
    unset -f _afd_proxy_setup _afd_proxy_encode
    if [[ "$_afd_proxy_trace" == 1 ]]; then
        unset _afd_proxy_trace
        set -x
    else
        unset _afd_proxy_trace
    fi
else
    unset -f _afd_proxy_setup _afd_proxy_encode
    if [[ "$_afd_proxy_trace" == 1 ]]; then
        unset _afd_proxy_trace
        set -x
    else
        unset _afd_proxy_trace
    fi
    return 1
fi

# ==========================================
# Troubleshooting（先基础设施，再软件配置）
# ==========================================
# 如果代理配置完成后仍然无法联网：
# 1. 检查宿主机上的 IPOP 是否正常启动。
# 2. 确认 IPOP 的代理映射正常，监听地址和端口可用。
# 3. 检查当前环境能否连接代理，例如 141.2.191.233:8080：
#      nc -vz 141.2.191.233 8080
# 4. 检查 Shell、Git、pip 的代理/源配置，以及其他作用域和环境变量的覆盖。
# 5. 如果只有 Git 失败，再排查 TLS 证书、动态库及 Git 配置来源。
#
# 检查代理链路（有超时，不自动执行；-v 可能暴露认证信息，不要直接分享输出）：
#   curl -v --connect-timeout 5 --max-time 20 --noproxy '' \
#     --proxy "${http_proxy}" https://github.com/
#
# 检查 Git 配置来源（结果含代理认证信息，发给别人前先脱敏）：
#   git config --show-origin --show-scope --get-all http.proxy
#   git config --show-origin --show-scope --get-all https.proxy
#   git config --show-origin --show-scope --get-urlmatch http.proxy https://github.com/
#   git config --show-origin --show-scope --get-urlmatch http.sslVerify https://github.com/
#   pip3 config debug
#
# 换 IP：export PROXY_IP=新IP，然后 source ./proxy.sh；密码从当前终端复用。
# 临时禁用 Git TLS 验证（仅确有需要时）：
#   export PROXY_INSECURE_SSL=1; source ./proxy.sh
# 恢复验证：export PROXY_INSECURE_SSL=0; source ./proxy.sh
#
# 注意：IPOP 未启动或代理映射失效时，修改 Git/pip 配置通常无法解决问题。
# TLS 证书错误与 EVP_md2/OPENSSL_x.y.z 动态库冲突不是同一类问题；
# 关闭证书验证无法修复动态库版本冲突。
