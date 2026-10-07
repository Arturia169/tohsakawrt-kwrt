#!/bin/sh
# 第 1 项：频段锁定的安全模式
#   ① lock 前必须保存原设置；非法输入拒绝且不碰模组
#   ② 观察期内 verify 不动手；到期探测通 → 确认；不通 → 自动恢复原设置并留痕
#   ③ restore 恢复保存的列表
# 全程桩件 AT 与 ping，不触碰真实模组
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-band" \
    "$ROOT/files/usr/bin/tohsakawrt-band" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${BAND_SCRIPT_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-band"; exit 1; }
[ -f "$SCRIPT" ] || { echo "FAIL: BAND_SCRIPT_OVERRIDE 指向的文件不存在"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir -p "$BIN"
CALLS="$TMP/calls.log"
export CALLS
export TWR_BAND_SAVED="$TMP/band-saved"
export TWR_BAND_PENDING="$TMP/band-pending"
export TWR_BAND_REVERTED="$TMP/band-reverted"
export TWR_BAND_AT_PORT="/dev/null"

# 桩件 AT：把命令记到 $CALLS，读命令返回 FAKE_CURRENT 指定的频段列表
# 调用约定与真实一致：sh <脚本> <端口> <命令> → 命令在 $2
cat > "$TMP/at.sh" <<'EOF'
#!/bin/sh
printf 'at %s\n' "$2" >> "$CALLS"
# FAKE_NO_READ=1 模拟"读不到频段"（返回空）
[ "${FAKE_NO_READ:-0}" = 1 ] && exit 0
case "$2" in
    'AT+QNWPREFCFG="nr5g_band"') echo "+QNWPREFCFG: \"nr5g_band\",${FAKE_CURRENT:-1:2:3:5:78:79}" ;;
    *) echo OK ;;
esac
EOF
chmod +x "$TMP/at.sh"
export TWR_BAND_AT_SCRIPT="$TMP/at.sh"

# 桩件 ping：由 TEST_DATA_OK 控制"5G 数据面是否通"
cat > "$BIN/ping" <<'EOF'
#!/bin/sh
printf 'ping %s\n' "$*" >> "$CALLS"
[ "${TEST_DATA_OK:-1}" = 1 ] && exit 0
exit 1
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}
reset_state() { rm -f "$TWR_BAND_SAVED" "$TWR_BAND_PENDING" "$TWR_BAND_REVERTED"; : > "$CALLS"; }

# ---------- show ----------
reset_state
check 'show 读出当前频段列表' "$([ "$("$SCRIPT" show 2>/dev/null)" = "1:2:3:5:78:79" ] && echo 1 || echo 0)"

# ---------- lock：保存原设置 + 写观察期 + 下发设置 ----------
reset_state
OUT="$("$SCRIPT" lock 78:1 2>&1)"
check 'lock 返回 OK_LOCKED' "$([ "$OUT" = "OK_LOCKED" ] && echo 1 || echo 0)"
check 'lock 前保存了原设置' "$([ "$(cat "$TWR_BAND_SAVED" 2>/dev/null)" = "1:2:3:5:78:79" ] && echo 1 || echo 0)"
check 'lock 下发目标频段列表' \
    "$(grep -Fq 'at AT+QNWPREFCFG="nr5g_band",78:1' "$CALLS" && echo 1 || echo 0)"
check 'lock 后做了射频软复位让设置生效' \
    "$(grep -Fq 'at AT+CFUN=0' "$CALLS" && grep -Fq 'at AT+CFUN=1' "$CALLS" && echo 1 || echo 0)"
check '写下了观察期记录（含未来截止时间与目标）' \
    "$(awk '{ if ($1 > 0 && $2 == "78:1") print "1" }' "$TWR_BAND_PENDING" 2>/dev/null | grep -q 1 && echo 1 || echo 0)"

# ---------- lock：非法输入必须拒绝且不碰模组 ----------
reset_state
if OUT="$("$SCRIPT" lock '78;rm' 2>&1)"; then rc=0; else rc=1; fi
check '非法频段列表被拒绝（非零退出 + ERROR_BAD_BAND）' \
    "$([ "$rc" -eq 1 ] && [ "$OUT" = "ERROR_BAD_BAND" ] && echo 1 || echo 0)"
check '非法输入没有下发任何 AT 设置命令' \
    "$(grep -q '^at AT+QNWPREFCFG="nr5g_band",' "$CALLS" && echo 0 || echo 1)"

# ---------- lock：读不到频段时不得锁 ----------
reset_state
if OUT="$(FAKE_NO_READ=1 "$SCRIPT" lock 78 2>&1)"; then rc=0; else rc=1; fi
check '读不到当前频段时拒绝锁定（ERROR_AT_FAILED）' \
    "$([ "$rc" -eq 1 ] && [ "$OUT" = "ERROR_AT_FAILED" ] && echo 1 || echo 0)"
check '拒绝时未写观察期记录' "$([ ! -f "$TWR_BAND_PENDING" ] && echo 1 || echo 0)"

# ---------- verify：观察期未到 → 什么都不做 ----------
reset_state
printf '1:2:3:5:78:79\n' > "$TWR_BAND_SAVED"
printf '%s 78\n' "$(( $(date +%s) + 999 ))" > "$TWR_BAND_PENDING"
TEST_DATA_OK=1 "$SCRIPT" verify >/dev/null 2>&1
check '观察期未到时 verify 不下发任何 AT 设置' \
    "$(grep -q '^at AT+QNWPREFCFG="nr5g_band",' "$CALLS" && echo 0 || echo 1)"
check '观察期未到时保留观察期记录' "$([ -f "$TWR_BAND_PENDING" ] && echo 1 || echo 0)"

# ---------- verify：到期且数据通 → 确认，不改设置 ----------
reset_state
printf '1:2:3:5:78:79\n' > "$TWR_BAND_SAVED"
printf '%s 78\n' "$(( $(date +%s) - 10 ))" > "$TWR_BAND_PENDING"
TEST_DATA_OK=1 "$SCRIPT" verify >/dev/null 2>&1
check '到期且数据面正常 → 清除观察期记录' "$([ ! -f "$TWR_BAND_PENDING" ] && echo 1 || echo 0)"
check '到期且数据面正常 → 不改动频段设置' \
    "$(grep -q '^at AT+QNWPREFCFG="nr5g_band",' "$CALLS" && echo 0 || echo 1)"
check '到期且数据面正常 → 没有回退留痕' "$([ ! -f "$TWR_BAND_REVERTED" ] && echo 1 || echo 0)"

# ---------- verify：到期但数据不通 → 自动回退到保存的列表 ----------
reset_state
printf '1:2:3:5:78:79\n' > "$TWR_BAND_SAVED"
printf '%s 78\n' "$(( $(date +%s) - 10 ))" > "$TWR_BAND_PENDING"
TEST_DATA_OK=0 "$SCRIPT" verify >/dev/null 2>&1
check '探测不通时自动恢复保存的原设置' \
    "$(grep -Fq 'at AT+QNWPREFCFG="nr5g_band",1:2:3:5:78:79' "$CALLS" && echo 1 || echo 0)"
check '回退后清除观察期记录' "$([ ! -f "$TWR_BAND_PENDING" ] && echo 1 || echo 0)"
check '回退留下了可查询的说明（note）' \
    "$([ -s "$TWR_BAND_REVERTED" ] && "$SCRIPT" note 2>/dev/null | grep -q '已自动恢复' && echo 1 || echo 0)"

# ---------- restore ----------
reset_state
printf '1:2:3:5:78:79\n' > "$TWR_BAND_SAVED"
OUT="$("$SCRIPT" restore 2>&1)"
check 'restore 返回 OK_RESTORED' "$([ "$OUT" = "OK_RESTORED" ] && echo 1 || echo 0)"
check 'restore 下发了保存的频段列表' \
    "$(grep -Fq 'at AT+QNWPREFCFG="nr5g_band",1:2:3:5:78:79' "$CALLS" && echo 1 || echo 0)"

# ---------- 缺少保存文件时用全频段兜底（绝不留在空频段） ----------
reset_state
OUT="$("$SCRIPT" restore 2>&1)"
check '缺少保存文件时用全频段兜底' \
    "$(grep -Fq 'at AT+QNWPREFCFG="nr5g_band",1:2:3:5:7:8:12:20:25:28:38:40:41:48:66:71:77:78:79' "$CALLS" && echo 1 || echo 0)"

check '脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
