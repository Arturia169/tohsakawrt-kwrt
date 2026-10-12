#!/bin/sh
# 网络黑匣子：文件型采集器（tohsakawrt-event-files）的游标与轮转判定
#
# 这里守的是一个真实踩过的坑：只记"读到第几行"是不够的 ——
# 文件被清空后重新长回超过旧行号时，tail -n +N 会静默跳过新文件的前 N 行，
# 于是「OpenClash 重启」这类事件整条丢失。所以位置里必须同时记字节数。
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
EVENT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin" "$ROOT/files/usr/bin"; do
    if [ -f "$cand/tohsakawrt-event-files" ] && [ -f "$cand/tohsakawrt-event" ]; then
        SCRIPT="$cand/tohsakawrt-event-files"; EVENT="$cand/tohsakawrt-event"; break
    fi
done
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-event-files"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
LOG="$TMP/events.log"
START="$TMP/openclash_start.log"
CORE="$TMP/openclash.log"
STATE="$TMP/state"
mkdir -p "$STATE"
export TWR_EVENT_LOG="$LOG" TWR_EVENT_BIN="$EVENT"
export TWR_OPENCLASH_START_LOG="$START" TWR_OPENCLASH_CORE_LOG="$CORE"
export TWR_EVENT_FILES_STATE="$STATE"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

: > "$LOG"
: > "$CORE"
# 真实格式：前 19 字符是本地时间，第 20 字符是空格，消息从第 21 字符起；
# 采集器按英文 [Tip] 标记白名单匹配（中文是我一开始想当然写错的）。
printf '%s\n' \
    '2026-10-13 01:00:00 [Tip] OpenClash Start Running...' \
    '2026-10-13 01:00:05 [Tip] OpenClash Start Successful!' > "$START"

"$SCRIPT" collect >/dev/null 2>&1
n1="$(wc -l < "$LOG")"
check '首次采集把已有日志行翻译成事件' "$([ "$n1" -ge 1 ] && echo 1 || echo 0)"

"$SCRIPT" collect >/dev/null 2>&1
n2="$(wc -l < "$LOG")"
check '重复采集不产生重复事件（游标生效）' "$([ "$n2" -eq "$n1" ] && echo 1 || echo 0)"

# 轮转：清空后重新长回【超过】上次行数 —— 只比行号会漏掉新文件的前 N 行
printf '%s\n' \
    '2026-10-13 02:00:00 [Tip] OpenClash Already Stop!' \
    '2026-10-13 02:00:01 [Tip] OpenClash Start Running...' \
    '2026-10-13 02:00:06 [Tip] OpenClash Start Successful!' \
    '2026-10-13 02:00:07 [Tip] OpenClash Restart...' > "$START"
"$SCRIPT" collect >/dev/null 2>&1
n3="$(wc -l < "$LOG")"
check '文件轮转（清空后长回更多行）仍能采到新事件' "$([ "$n3" -gt "$n2" ] && echo 1 || echo 0)"

# 位置文件里必须同时存行号与字节数（这是轮转判定的依据）
posfile="$(ls "$STATE"/event-files-*.pos 2>/dev/null | head -n 1)"
fields="$(awk '{print NF}' "$posfile" 2>/dev/null)"
check '位置文件同时记录行号/字节数/校验和（≥3 段）' \
    "$([ -n "${posfile:-}" ] && [ "${fields:-0}" -ge 3 ] && echo 1 || echo 0)"

# status 子命令可用（排查用）
"$SCRIPT" status >/dev/null 2>&1
check 'status 子命令可正常执行' "$([ "$?" -eq 0 ] && echo 1 || echo 0)"

printf '\nPASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
