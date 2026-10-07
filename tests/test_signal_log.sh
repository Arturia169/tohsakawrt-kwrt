#!/bin/sh
# 第 3 项：信号趋势脚本的汇总与容错
#   ① show 能把样本汇总成"频段驻留/跳变 + RSRP/SINR 最差-平均-最好"
#   ② 没有样本文件 / 时间窗内无样本时给出友好提示且退出码 0
#   ③ record 在拿不到模组信息时什么都不写（不写脏数据），且不崩溃
set -u
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-signal-log" \
    "$ROOT/files/usr/bin/tohsakawrt-signal-log" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${SIGNAL_SCRIPT_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-signal-log"; exit 1; }
[ -f "$SCRIPT" ] || { echo "FAIL: SIGNAL_SCRIPT_OVERRIDE 指向的文件不存在: $SCRIPT"; exit 1; }

LUA_ROOT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/lib/lua" "$ROOT/files/usr/lib/lua"; do
    [ -f "$cand/tohsakawrt/core.lua" ] && LUA_ROOT="$cand" && break
done
[ -n "$LUA_ROOT" ] || { echo "FAIL: 找不到 lua 负载"; exit 1; }
export LUA_PATH="$LUA_ROOT/?.lua;$LUA_ROOT/?/init.lua;;"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
LOG="$TMP/trend.log"
export TOHSAKA_SIGNAL_LOG="$LOG"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

NOW="$(date +%s)"
# 造 6 条样本：n78 x4（RSRP -80 上下）→ n1 x2（RSRP -90 上下），跨一次频段跳变
{
    echo "$((NOW - 300)) n78 -75 22 -9 534 170951101"
    echo "$((NOW - 240)) n78 -78 20 -10 534 170951101"
    echo "$((NOW - 180)) n78 -80 18 -11 534 170951101"
    echo "$((NOW - 120)) n78 -82 16 -12 534 170951101"
    echo "$((NOW - 60))  n1  -90 9  -14 201 170951999"
    echo "$NOW n1  -92 8  -15 201 170951999"
} > "$LOG"

OUT="$(lua "$SCRIPT" show 60 2>&1)"
check '汇总统计到 6 条样本' "$(printf '%s' "$OUT" | grep -q '<code>6</code> 条' && echo 1 || echo 0)"
check '报告两个频段及各自次数' \
    "$(printf '%s' "$OUT" | grep -q 'n78 <code>4</code> 次' && printf '%s' "$OUT" | grep -q 'n1 <code>2</code> 次' && echo 1 || echo 0)"
check '统计到 1 次频段跳变' "$(printf '%s' "$OUT" | grep -q '跳变 <code>1</code> 次' && echo 1 || echo 0)"
check 'RSRP 最差 -92 / 最好 -75' \
    "$(printf '%s' "$OUT" | grep -q '最差 <code>-92</code>' && printf '%s' "$OUT" | grep -q '最好 <code>-75</code>' && echo 1 || echo 0)"
check 'SINR 最低 8 / 最高 22' \
    "$(printf '%s' "$OUT" | grep -q '最低 <code>8</code>' && printf '%s' "$OUT" | grep -q '最高 <code>22</code>' && echo 1 || echo 0)"

# 平均值必须精确：RSRP (-75-78-80-82-90-92)/6 = -82.83 → -83；SINR (22+20+18+16+9+8)/6 = 15.5 → 16
AVG_R="$(printf '%s' "$OUT" | sed -n 's/.*平均 <code>\(-\{0,1\}[0-9]*\)<\/code>.*/\1/p' | head -n 1)"
AVG_S="$(printf '%s' "$OUT" | sed -n 's/.*平均 <code>\(-\{0,1\}[0-9]*\)<\/code>.*/\1/p' | tail -n 1)"
check 'RSRP 平均值按四舍五入为 -83' "$([ "$AVG_R" = "-83" ] && echo 1 || echo 0)"
check 'SINR 平均值按四舍五入为 16' "$([ "$AVG_S" = "16" ] && echo 1 || echo 0)"

# 时间窗过滤：只看最近 90 秒 → 只应统计到最后两条（n1）
OUT2="$(lua "$SCRIPT" show 1 2>&1)"
check '时间窗过滤生效（最近 1 分钟只剩 n1 的样本）' \
    "$(printf '%s' "$OUT2" | grep -q 'n1' && ! printf '%s' "$OUT2" | grep -q 'n78' && echo 1 || echo 0)"

# 空文件 / 文件不存在
: > "$LOG"
OUT3="$(lua "$SCRIPT" show 60 2>&1)"
check '窗口内无样本时给出提示且退出码 0' \
    "$([ $? -eq 0 ] && printf '%s' "$OUT3" | grep -q '没有样本' && echo 1 || echo 0)"
rm -f "$LOG"
OUT4="$(lua "$SCRIPT" show 60 2>&1)"
rc=$?
check '样本文件不存在时给出提示且退出码 0' \
    "$([ "$rc" -eq 0 ] && printf '%s' "$OUT4" | grep -q '还没有样本' && echo 1 || echo 0)"

# record：非零退出（本机没有模组），且不得写出脏数据
rm -f "$LOG"
if lua "$SCRIPT" record >/dev/null 2>&1; then rec_rc=0; else rec_rc=1; fi
check '无模组时 record 明确失败（非零退出）' "$([ "$rec_rc" -eq 1 ] && echo 1 || echo 0)"
check '无模组时 record 不写出任何样本（不写脏数据）' \
    "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

check '脚本可执行位已设置' "$([ -x "$SCRIPT" ] && echo 1 || echo 0)"

# 用桩件模组验证 record 写出的样本格式（info() 返回的是 "-10 dB" 这类带单位的字符串，必须剥掉）
STUB="$TMP/luastub"
mkdir -p "$STUB/tohsakawrt"
cat > "$STUB/tohsakawrt/modem.lua" <<'LUA'
return { info = function()
    return { band = "n78", rsrp = "-79 dBm", rsrp_num = -79, sinr = "17 dB", sinr_num = 17,
             rsrq = "-10 dB", pci = "534", cell_id = "170951101" }
end }
LUA
rm -f "$LOG"
LUA_PATH="$STUB/?.lua;$LUA_ROOT/?.lua;$LUA_ROOT/?/init.lua;;" lua "$SCRIPT" record >/dev/null 2>&1
check '桩件模组下 record 写出样本' "$([ -s "$LOG" ] && echo 1 || echo 0)"
LINE="$(cat "$LOG" 2>/dev/null)"
check '样本字段顺序为 epoch band rsrp sinr rsrq pci cid' \
    "$(printf '%s' "$LINE" | grep -Eq '^[0-9]+ n78 -79 17 -10 534 170951101$' && echo 1 || echo 0)"
check '样本里不残留 dB / dBm 单位' \
    "$(printf '%s' "$LINE" | grep -q 'dB' && echo 0 || echo 1)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
