#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin"
printf '%s\n' 'abc' > "$TMP/temp"
cat > "$TMP/bin/uci" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$TMP/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
SH
chmod +x "$TMP/bin/uci" "$TMP/bin/logger"
TARGET=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-temp-watch" \
            "$ROOT/files/usr/bin/tohsakawrt-temp-watch"; do
    [ -f "$cand" ] && TARGET="$cand" && break
done
[ -n "${TARGET:-}" ] || { echo "FAIL: 找不到负载"; exit 1; }
TEST_LOG="$TMP/log" PATH="$TMP/bin:$PATH" TWR_TEMP_FILE="$TMP/temp" sh "$TARGET"
if [ -f "$TMP/log" ] && grep -Fxq -- '-t TohsakaWrt-Temp Invalid CPU temperature reading; skipping this check' "$TMP/log"; then
    echo 'PASS: invalid temperature is logged and exits cleanly'
else
    echo 'FAIL: 期望负载记录「Invalid CPU temperature reading; skipping this check」'
    echo '--- 实际日志 ---'
    cat "$TMP/log" 2>/dev/null || echo '(日志文件不存在)'
    exit 1
fi
