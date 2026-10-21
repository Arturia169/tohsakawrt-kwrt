#!/bin/sh
# 热重载脚本：成功 / 被内核拒绝 / 内核不可用 三条路径，以及 -o/-n/-q/-r 开关
# 全程用临时文件 + 桩件 curl/init，不碰真实 Clash 配置与 OpenClash 服务
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-clash-reload" \
    "$ROOT/files/usr/bin/tohsakawrt-clash-reload" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${CLASH_RELOAD_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-clash-reload"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/curl.log"
INITLOG="$TMP/init.log"
STARTED="$TMP/started"
MODE_400="$TMP/mode400"
MODE_000="$TMP/mode000"
export CALLS INITLOG STARTED MODE_400 MODE_000

# 桩件 curl：按 /version 与 /configs 分别回话，行为由标记文件切换
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$CALLS"
case "$*" in
    */version*)
        [ -f "$STARTED" ] && printf '{"version":"test"}\n' || printf '\n'
        ;;
    *configs*)
        if [ -f "$MODE_400" ]; then
            printf '{"message":"proxy group[1]: boom"}\n400'
        elif [ -f "$MODE_000" ]; then
            printf '000'
        else
            printf '\n204'
        fi
        ;;
    *) printf '\n' ;;
esac
EOF

# 桩件 init：记录调用，并把内核标记成"已起来"
cat > "$BIN/openclash" <<'EOF'
#!/bin/sh
printf 'init %s\n' "$*" >> "$INITLOG"
touch "$STARTED"
exit 0
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

export TWR_CLASH_API="http://127.0.0.1:9090"
export TWR_CLASH_RUNTIME="$TMP/runtime.yaml"
export TWR_CLASH_INIT="$BIN/openclash"
export TWR_CLASH_RELOAD_LOG="$TMP/reload.log"
export TWR_CLASH_RELOAD_LOCK="$TMP/lock"
export TWR_CLASH_RELOAD_TRIES=1
export TWR_CLASH_OVERWRITE="$TMP/overwrite.sh"

reset() {
    : > "$CALLS"
    : > "$INITLOG"
    rm -f "$MODE_400" "$MODE_000" "$STARTED" "$TMP/ov.marker"
    printf 'rules: []\n' > "$TWR_CLASH_RUNTIME"
}

pass=0; fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

# ---------- 正常热重载 ----------
reset; touch "$STARTED"
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
check '成功时退出码 0' "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check '提示已热重载' "$(printf '%s' "$OUT" | grep -q '已热重载' && echo 1 || echo 0)"
check '调用了 PUT /configs 且带 force=true' \
    "$(grep -q 'X PUT http://127.0.0.1:9090/configs?force=true' "$CALLS" && echo 1 || echo 0)"
check '请求体指向运行配置' \
    "$(grep -q "$TMP/runtime.yaml" "$CALLS" && echo 1 || echo 0)"
check '成功时没有触发完整重启' "$([ ! -s "$INITLOG" ] && echo 1 || echo 0)"

# ---------- 配置被内核拒绝 ----------
reset; touch "$STARTED" "$MODE_400"
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
check '被拒时退出码 2' "$([ "$rc" -eq 2 ] && echo 1 || echo 0)"
check '把内核的报错原样带出来' "$(printf '%s' "$OUT" | grep -q 'boom' && echo 1 || echo 0)"
check '被拒时不重启（旧配置继续服务）' "$([ ! -s "$INITLOG" ] && echo 1 || echo 0)"

# ---------- 被拒 + -r 强制重启 ----------
reset; touch "$STARTED" "$MODE_400"
if "$SCRIPT" -r >/dev/null 2>&1; then rc=0; else rc=$?; fi
check '-r 时改为完整重启' "$(grep -q 'init restart' "$INITLOG" && echo 1 || echo 0)"
check '-r 重启成功后退出码 0' "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"

# ---------- 内核不可用 -> 自动重启 ----------
reset; touch "$MODE_000"
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
check '接口不可达时自动重启' "$(grep -q 'init restart' "$INITLOG" && echo 1 || echo 0)"
check '自动重启成功后退出码 0' "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"

# ---------- -n：不许重启 ----------
reset; touch "$MODE_000"
if OUT="$("$SCRIPT" -n 2>&1)"; then rc=0; else rc=$?; fi
check '-n 时退出码 3' "$([ "$rc" -eq 3 ] && echo 1 || echo 0)"
check '-n 时没有重启' "$([ ! -s "$INITLOG" ] && echo 1 || echo 0)"

# ---------- -q 静默 ----------
reset; touch "$STARTED"
OUT="$("$SCRIPT" -q 2>&1)"
check '-q 时无标准输出' "$([ -z "$OUT" ] && echo 1 || echo 0)"
check '-q 仍然写了日志' "$([ -s "$TWR_CLASH_RELOAD_LOG" ] && echo 1 || echo 0)"

# ---------- -o：覆盖脚本成功 ----------
reset; touch "$STARTED"
cat > "$TWR_CLASH_OVERWRITE" <<EOF
#!/bin/sh
printf 'ov\n' > "$TMP/ov.marker"
EOF
if "$SCRIPT" -o >/dev/null 2>&1; then rc=0; else rc=$?; fi
check '-o 先执行覆盖脚本' "$([ -f "$TMP/ov.marker" ] && echo 1 || echo 0)"
check '-o 之后仍然热重载' "$(grep -q 'X PUT' "$CALLS" && echo 1 || echo 0)"

# ---------- -o：覆盖脚本失败则不重载 ----------
reset; touch "$STARTED"
printf '#!/bin/sh\nexit 1\n' > "$TWR_CLASH_OVERWRITE"
if "$SCRIPT" -o >/dev/null 2>&1; then rc=0; else rc=$?; fi
check '覆盖脚本失败时退出码 1' "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
check '覆盖脚本失败时不发重载请求' "$([ ! -s "$CALLS" ] && echo 1 || echo 0)"

# ---------- 参数与语法 ----------
if "$SCRIPT" -Z >/dev/null 2>&1; then rc=0; else rc=$?; fi
check '非法参数退出码 1' "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
check '脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
