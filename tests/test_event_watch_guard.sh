#!/bin/sh
# 网络黑匣子：异常检测器（tohsakawrt-event-watch）的告警节制与安全护栏
#
# 这里守两条线：
#   ① 安全护栏 —— 读非生产事件文件时绝不允许发真实通知。
#      这是 2026-10-10 的真事故：拿临时事件文件测阈值却忘了设 DRY，
#      结果"读假数据、发真 Telegram"，用户凭空收到 3 条误报。
#   ② 告警节制 —— 同类异常在冷却期内只告警一次，绝不刷屏。
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-event-watch" \
            "$ROOT/files/usr/bin/tohsakawrt-event-watch"; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-event-watch"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
LOG="$TMP/events.log"
STATE="$TMP/state"
BIN="$TMP/bin"
mkdir -p "$STATE" "$BIN"

# 假的投递通道：只记录"被调用过"，绝不真的发消息
cat > "$BIN/send_tg_bg" <<'SH'
#!/bin/sh
printf 'TG %s\n' "$1" >> "$DELIVERY_LOG"
SH
cat > "$BIN/push_bark_bg" <<'SH'
#!/bin/sh
printf 'BARK %s\n' "$1" >> "$DELIVERY_LOG"
SH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export DELIVERY_LOG="$TMP/delivery.log"
export TWR_EVENT_LOG="$LOG" TWR_EVENT_WATCH_STATE="$STATE"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

NOW="$(date +%s)"
# 制造"制式抖动"：30 分钟内 5 次 rat 事件（常态阈值 4 次）
i=0
while [ "$i" -lt 5 ]; do
    printf '%s info rat watch 制式切换\n' "$((NOW - 600 + i * 60))" >> "$LOG"
    i=$((i + 1))
done
: > "$DELIVERY_LOG"

# ---------- ① 安全护栏：非生产事件文件绝不投递 ----------
out="$(TWR_EVENT_WATCH_NOW="$NOW" "$SCRIPT" run 2>&1)"
check '检测到制式抖动并给出告警正文' "$(printf '%s' "$out" | grep -q '制式' && echo 1 || echo 0)"
check '事件文件非生产路径时强制不投递（2026-10-10 事故的回归测试）' \
    "$([ ! -s "$DELIVERY_LOG" ] && echo 1 || echo 0)"

# ---------- ② 显式放行后才真正投递 ----------
rm -rf "$STATE"; mkdir -p "$STATE"
TWR_EVENT_WATCH_ALLOW_REAL=1 TWR_EVENT_WATCH_NOW="$NOW" "$SCRIPT" run >/dev/null 2>&1
check '显式设 TWR_EVENT_WATCH_ALLOW_REAL=1 后才投递' \
    "$([ -s "$DELIVERY_LOG" ] && echo 1 || echo 0)"

# ---------- ③ 冷却：同类异常重复触发不再告警 ----------
: > "$DELIVERY_LOG"
TWR_EVENT_WATCH_ALLOW_REAL=1 TWR_EVENT_WATCH_NOW="$NOW" "$SCRIPT" run >/dev/null 2>&1
check '冷却期内重复触发不再告警（防刷屏）' "$([ ! -s "$DELIVERY_LOG" ] && echo 1 || echo 0)"

# ---------- ④ check 子命令只检测、不投递 ----------
: > "$DELIVERY_LOG"
TWR_EVENT_WATCH_ALLOW_REAL=1 TWR_EVENT_WATCH_NOW="$NOW" "$SCRIPT" check >/dev/null 2>&1
check 'check 子命令只检测、不投递' "$([ ! -s "$DELIVERY_LOG" ] && echo 1 || echo 0)"

# ---------- ⑤ status 子命令可用（排查用） ----------
TWR_EVENT_WATCH_NOW="$NOW" "$SCRIPT" status >/dev/null 2>&1
check 'status 子命令可正常执行' "$([ "$?" -eq 0 ] && echo 1 || echo 0)"

printf '\nPASS=%d FAIL=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
