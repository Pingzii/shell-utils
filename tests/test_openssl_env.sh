#!/usr/bin/env bash
# 不联网、不安装软件；用替身检查构建子进程的 Git 环境。
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/afd-env-test.XXXXXXXX")"
cleanup_test()
{
    rm -f -- "$test_dir/git-real" "$test_dir/python3"
    rmdir -- "$test_dir"
}
trap cleanup_test EXIT

cat > "$test_dir/git-real" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" != --fail-42 ]] || exit 42
printf 'git|%s|%s|%s\n' "${LD_LIBRARY_PATH-<unset>}" "${LD_PRELOAD-<unset>}" "$*"
SH
cat > "$test_dir/python3" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'python|%s\n' "$LD_LIBRARY_PATH"
# 两种外部进程调用，均不依赖父 shell 的 Git 函数。
env git "from direct child"
bash -c 'git "from bash child"'
SH
chmod 700 "$test_dir/git-real" "$test_dir/python3"

for original in '/cann/lib:/other/lib' '/test/openssl/lib/:/cann/lib:/test/openssl/lib' ''; do
    (
        export PATH="$test_dir:$PATH"
        export SYSTEM_GIT_BIN="$test_dir/git-real"
        export TMPDIR="$test_dir"
        export OPENSSL35_PATH=/test/openssl/lib
        export LD_LIBRARY_PATH="$original"
        export LD_PRELOAD=''
        # 只加载环境函数，不运行真正的 clone/build。
        source <(tr -d '\r' < "$repo_dir/afd_build_and_compile.sh" | sed '/^FORCE=0/,$d')
        init_git_env
        [[ "$(git 'argument with spaces')" == 'git|<unset>|<unset>|argument with spaces' ]]
        case "$original" in
            '/cann/lib:/other/lib') base='/cann/lib:/other/lib' ;;
            '/test/openssl/lib/:/cann/lib:/test/openssl/lib') base='/cann/lib' ;;
            '') base='' ;;
        esac
        expected="python|/test/openssl/lib${base:+:$base}"$'\n'
        expected+='git|<unset>|<unset>|from direct child'$'\n'
        expected+='git|<unset>|<unset>|from bash child'
        [[ "$(python3)" == "$expected" ]]
        [[ "$LD_LIBRARY_PATH" == "$original" && "${LD_PRELOAD+x}" == x ]]
        if git --fail-42; then
            echo 'FAIL: Git exit status was lost' >&2
            exit 1
        else
            [[ $? -eq 42 ]]
        fi
    )
    if compgen -G "$test_dir/afd-git-env.*" > /dev/null; then
        echo 'FAIL: Git wrapper was not cleaned up' >&2
        exit 1
    fi
    printf 'PASS: nested Git isolation, Python paths, arguments, status, cleanup (%s)\n' "${original:-empty}"
done
