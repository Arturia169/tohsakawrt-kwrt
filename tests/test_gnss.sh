#!/bin/sh
# GNSS 定位脚本：三种状态与开关
#   ① 未开启 → 提示开启
#   ② 已开启未定位（+QGPSLOC 无返回）→ 提示搜星中
#   ③ 有定位 → 坐标 + 地图链接（+ 可选距参考点距离）
# 全程桩件 AT，不触碰真实模组
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-gnss" \
    "$ROOT/files/usr/bin/tohsakawrt-gnss" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${GNSS_SCRIPT_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-gnss"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CALLS="$TMP/calls.log"
export CALLS
export TWR_GNSS_AT_PORT="/dev/null"
STATE="$TMP/gps-state"
echo 0 > "$STATE"
export FAKE_GPS_STATE="$STATE"

# 有状态的桩件：AT+QGPS=1 打开、AT+QGPSEND 关闭、AT+QGPS? 读状态
cat > "$TMP/at.sh" <<'EOF'
#!/bin/sh
printf 'at %s\n' "$2" >> "$CALLS"
case "$2" in
    'AT+QGPS?')      printf '+QGPS: %s\n' "$(cat "$FAKE_GPS_STATE" 2>/dev/null || echo 0)" ;;
    'AT+QGPS=1')     echo 1 > "$FAKE_GPS_STATE"; echo OK ;;
    'AT+QGPSEND')    echo 0 > "$FAKE_GPS_STATE"; echo OK ;;
    'AT+QGPSLOC?')   [ -n "${FAKE_LOC:-}" ] && echo "$FAKE_LOC" ;;
    *) echo OK ;;
esac
EOF
chmod +x "$TMP/at.sh"
export TWR_GNSS_AT_SCRIPT="$TMP/at.sh"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}
reset() { : > "$CALLS"; echo 0 > "$STATE"; unset FAKE_LOC 2>/dev/null || true; }

# ---------- 未开启 ----------
reset
OUT="$("$SCRIPT" show 2>&1)"
check '未开启时提示开启' "$(printf '%s' "$OUT" | grep -q '未开启' && echo 1 || echo 0)"

# ---------- start ----------
reset
OUT="$("$SCRIPT" start 2>&1)"
check 'start 下发 AT+QGPS=1 并返回 OK_STARTED' \
    "$([ "$OUT" = "OK_STARTED" ] && grep -Fq 'at AT+QGPS=1' "$CALLS" && echo 1 || echo 0)"
check 'start 后模组状态确实变为开启' "$([ "$(cat "$STATE")" = "1" ] && echo 1 || echo 0)"

# ---------- 已开启但还没定位 ----------
reset
echo 1 > "$STATE"
OUT="$("$SCRIPT" show 2>&1)"
check '已开启未定位时提示正在搜星' \
    "$(printf '%s' "$OUT" | grep -q '正在搜星' && echo 1 || echo 0)"

# ---------- 有定位 ----------
reset
echo 1 > "$STATE"
FAKE_LOC='+QGPSLOC: 091208.0,30.572815,104.066801,0.9,512.0,2,0.0,0.0,0.0,1.1,1.4'
export FAKE_LOC
OUT="$("$SCRIPT" show 2>&1)"
check '有定位时给出坐标' "$(printf '%s' "$OUT" | grep -q '30.572815, 104.066801' && echo 1 || echo 0)"
check '有定位时给出地图链接（OpenStreetMap）' \
    "$(printf '%s' "$OUT" | grep -q 'openstreetmap.org/?mlat=30.572815&mlon=104.066801' && echo 1 || echo 0)"
check '有定位时给出海拔与精度' \
    "$(printf '%s' "$OUT" | grep -q '512.0' && printf '%s' "$OUT" | grep -q '0.9' && echo 1 || echo 0)"

# ---------- 距参考点 ----------
OUT2="$("$SCRIPT" show '30.600000,104.100000' 2>&1)"
check '给出与参考点的直线距离' "$(printf '%s' "$OUT2" | grep -q '距参考点' && echo 1 || echo 0)"
check '距离数值合理（约 3~4 km）' \
    "$(printf '%s' "$OUT2" | sed -n 's/.*约 <code>\([0-9.]*\)<\/code> km.*/\1/p' | awk '{ if ($1 > 2 && $1 < 5) print "1" }' | grep -q 1 && echo 1 || echo 0)"

# ---------- stop ----------
reset
echo 1 > "$STATE"
OUT="$("$SCRIPT" stop 2>&1)"
check 'stop 下发 AT+QGPSEND 并返回 OK_STOPPED' \
    "$([ "$OUT" = "OK_STOPPED" ] && grep -Fq 'at AT+QGPSEND' "$CALLS" && echo 1 || echo 0)"
check 'stop 后模组状态确实变为关闭' "$([ "$(cat "$STATE")" = "0" ] && echo 1 || echo 0)"
check '脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
