#!/bin/sh
# 网络黑匣子：时间线读取器（tohsakawrt-event-log）的过滤、分页与纯文本模式
#
# 用户看的就是这一层，过滤写错会让人"以为那段时间没事"，比不显示更危险。
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-event-log" \
            "$ROOT/files/usr/bin/tohsakawrt-event-log"; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-event-log"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
LOG="$TMP/events.log"
export TWR_EVENT_LOG="$LOG" TWR_EVENT_MAX_SHOW=500

# 时间戳必须贴近"现在"：读取器把展示窗口封顶在 720 小时（30 天），
# 用 2023 年的固定时间戳会落进"共 N 条历史"里而看不到正文（我第一版就踩了这个）。
NOW="$(date +%s)"
{
    printf '%s info avail watch 网络已恢复\n'      "$((NOW - 500))"
    printf '%s warn rat watch 制式抖动\n'          "$((NOW - 400))"
    printf '%s error uplink uplink 切换出口失败\n' "$((NOW - 300))"
    printf '%s crit avail watch 检测到断网\n'      "$((NOW - 200))"
    printf '%s info bot bot 用户点击了按钮\n'      "$((NOW - 100))"
} > "$LOG"
BEFORE="$((NOW - 250))"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

# 它是 Lua 脚本（shebang 指 /usr/bin/lua，那是设备上的路径）。N100 上没有这个路径，
# 所以必须显式用 lua 解释器跑，不能靠 shebang，也不能用 sh。
run() { lua "$SCRIPT" "$@" 2>&1; }

# 窗口给得足够大，保证上面这些历史时间戳都在范围内
all="$(run show 24 --text)"
check '默认展示全部 5 条事件' \
    "$([ "$(printf '%s' "$all" | grep -c '网络已恢复\|制式抖动\|切换出口失败\|检测到断网\|用户点击了按钮')" -eq 5 ] && echo 1 || echo 0)"

warn_only="$(run show 24 --text --level warn)"
check '--level warn 含 warn/error/crit，排除 info' \
    "$(printf '%s' "$warn_only" | grep -q '制式抖动' && printf '%s' "$warn_only" | grep -q '检测到断网' && ! printf '%s' "$warn_only" | grep -q '用户点击了按钮' && echo 1 || echo 0)"

err_only="$(run show 24 --text --level error)"
check '--level error 只含 error/crit' \
    "$(printf '%s' "$err_only" | grep -q '切换出口失败' && printf '%s' "$err_only" | grep -q '检测到断网' && ! printf '%s' "$err_only" | grep -q '制式抖动' && echo 1 || echo 0)"

kind_only="$(run show 24 --text --kind rat)"
check '--kind rat 只留制式类事件' \
    "$(printf '%s' "$kind_only" | grep -q '制式抖动' && ! printf '%s' "$kind_only" | grep -q '用户点击了按钮' && echo 1 || echo 0)"

multi_kind="$(run show 24 --text --kind rat,uplink)"
check '--kind 支持逗号多值' \
    "$(printf '%s' "$multi_kind" | grep -q '制式抖动' && printf '%s' "$multi_kind" | grep -q '切换出口失败' && echo 1 || echo 0)"

kw="$(run show 24 --text 抖动)"
check '关键词按字面匹配 message' \
    "$(printf '%s' "$kw" | grep -q '制式抖动' && ! printf '%s' "$kw" | grep -q '网络已恢复' && echo 1 || echo 0)"

before="$(run show 24 --text --before "$BEFORE")"
check '--before 只显示该时刻之前的事件（往回翻页）' \
    "$(printf '%s' "$before" | grep -q '切换出口失败' && ! printf '%s' "$before" | grep -q '检测到断网' && echo 1 || echo 0)"

html="$(run show 24)"
check '默认输出带 HTML 标签（供 Telegram 渲染）' \
    "$(printf '%s' "$html" | grep -q '<' && echo 1 || echo 0)"
check '--text 输出不含 HTML 标签' \
    "$(printf '%s' "$all" | grep -q '<' && echo 0 || echo 1)"


old_window="$(run show 1 --text --before "$((NOW - 86400 * 400))")"
check '窗口外的历史事件会被明确提示（共 N 条历史）' \
    "$(printf '%s' "$old_window" | grep -q '共' && printf '%s' "$old_window" | grep -q '条历史' && echo 1 || echo 0)"

printf '\nPASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
