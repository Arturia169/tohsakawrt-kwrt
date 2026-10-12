#!/bin/sh
# 网络黑匣子：事件写入器（tohsakawrt-event）的字段规范、归一与轮转
#
# 这个脚本被所有来源频繁调用，格式一旦写坏，后面的事件读取器/因果关联全都失准，
# 所以这里把"字段结构"和"绝不报错"当成硬约束来测。
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-event" \
            "$ROOT/files/usr/bin/tohsakawrt-event"; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-event"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
LOG="$TMP/events.log"
export TWR_EVENT_LOG="$LOG"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

# ---------- ① 基本写入：固定 5 段，前 4 段不含空格 ----------
: > "$LOG"
TWR_EVENT_TS=1700000000 "$SCRIPT" warn rat watch "制式抖动 3 次"
check '写入一行且时间戳/级别/类别/来源正确' \
    "$(grep -qx '1700000000 warn rat watch 制式抖动 3 次' "$LOG" && echo 1 || echo 0)"
check '前 4 段不含空格（解析方式唯一）' \
    "$([ "$(awk 'NR==1{print NF}' "$LOG")" -ge 5 ] && [ "$(awk 'NR==1{print $2}' "$LOG")" = "warn" ] && echo 1 || echo 0)"

# ---------- ② 非法 level/kind/actor 必须归一（含空格会破坏字段结构）----------
: > "$LOG"
TWR_EVENT_TS=1700000001 "$SCRIPT" "bad level" "Bad Kind" "bad actor" "消息正文"
check '非法 level/kind/actor 归一为 info/sys/sys' \
    "$(grep -qx '1700000001 info sys sys 消息正文' "$LOG" && echo 1 || echo 0)"

# ---------- ③ 时间戳：可指定历史时间，非法值回落当前时间 ----------
: > "$LOG"
TWR_EVENT_TS="not-a-number" "$SCRIPT" info sys test "坏时间戳"
ts="$(awk 'NR==1{print $1}' "$LOG")"
case "$ts" in ''|*[!0-9]*) ok=0 ;; *) [ "$ts" -gt 1600000000 ] && ok=1 || ok=0 ;; esac
check '非法 TWR_EVENT_TS 回落为当前时间（绝不写出坏时间戳）' "$ok"
: > "$LOG"
"$SCRIPT" info sys test "无时间戳"
ts="$(awk 'NR==1{print $1}' "$LOG")"
case "$ts" in ''|*[!0-9]*) ok=0 ;; *) [ "$ts" -gt 1600000000 ] && ok=1 || ok=0 ;; esac
check '未指定 TWR_EVENT_TS 时用当前时间' "$ok"

# ---------- ④ 参数不全：静默退出，绝不报错、绝不写半条 ----------
: > "$LOG"
out="$("$SCRIPT" warn rat 2>&1)"; rc=$?
check '参数不全时退出码 0 且无任何输出' "$([ "$rc" -eq 0 ] && [ -z "$out" ] && echo 1 || echo 0)"
check '参数不全时不写入任何内容' "$([ ! -s "$LOG" ] && echo 1 || echo 0)"

# ---------- ⑤ 说明部分是自由文本（空格/中文/标点都允许）----------
: > "$LOG"
TWR_EVENT_TS=1700000002 "$SCRIPT" info bot bot "机器人已启动，用时 1.2 秒（含中文与标点）"
check '说明部分允许空格/中文/标点' \
    "$(grep -q '机器人已启动，用时 1.2 秒（含中文与标点）$' "$LOG" && echo 1 || echo 0)"

# ---------- ⑥ 轮转：按文件大小触发，只保留最近 N 行 ----------
: > "$LOG"
i=0
while [ "$i" -lt 120 ]; do
    TWR_EVENT_TS=$((1700000000 + i)) "$SCRIPT" info sys fill "填充内容填充内容填充内容第 $i 条"
    i=$((i + 1))
done
before="$(wc -l < "$LOG")"
TWR_EVENT_MAX_BYTES=200 TWR_EVENT_KEEP_LINES=20 "$SCRIPT" info sys fill "触发轮转"
after="$(wc -l < "$LOG")"
check '超过 MAX_BYTES 时轮转，只保留 KEEP_LINES 行' \
    "$([ "$before" -gt 20 ] && [ "$after" -le 20 ] && echo 1 || echo 0)"
check '轮转后文件仍可正常追加（不会卡死）' \
    "$(TWR_EVENT_TS=1700000999 "$SCRIPT" info sys fill "轮转后新事件"; grep -q '轮转后新事件' "$LOG" && echo 1 || echo 0)"

printf '\nPASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
