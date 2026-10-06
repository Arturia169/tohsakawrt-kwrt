#!/bin/sh
# 告警带按钮 + 投递校验：桩件 curl/uci/logger，不发真实消息、不写真实 syslog
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
COMMON=""
for candidate in \
    "$ROOT/devices/mediatek_filogic/files/usr/lib/tohsakawrt/common.sh" \
    "$ROOT/files/usr/lib/tohsakawrt/common.sh" ; do
    [ -f "$candidate" ] && COMMON="$candidate" && break
done
COMMON="${COMMON_SH_OVERRIDE:-${COMMON:-$ROOT/files/usr/lib/tohsakawrt/common.sh}}"
[ -f "$COMMON" ] || { echo "FAIL: cannot locate common.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir -p "$BIN"
CALLS="$TMP/curl.args"
COUNT="$TMP/curl.count"
LOGS="$TMP/logger.log"
CURL_MODE="${CURL_MODE:-ok}"
UCI_TOKEN="${UCI_TOKEN:-test-token}"
UCI_CHAT="${UCI_CHAT:-123456}"
UCI_ENABLED="${UCI_ENABLED:-1}"
export CALLS COUNT LOGS CURL_MODE UCI_TOKEN UCI_CHAT UCI_ENABLED

cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CALLS"
n=$(cat "$COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$n" > "$COUNT"
case "${CURL_MODE:-ok}" in
    fail)      printf '%s' '{"ok":false,"error_code":400,"description":"Bad Request: test"}' ;;
    fail_once) if [ "$n" -eq 1 ]; then
                   printf '%s' '{"ok":false,"error_code":500,"description":"boom"}'
               else
                   printf '%s' '{"ok":true,"result":{"message_id":2}}'
               fi ;;
    *)         printf '%s' '{"ok":true,"result":{"message_id":1}}' ;;
esac
exit 0
EOF
cat > "$BIN/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGS"
EOF
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
case "$*" in
    *token*)   printf '%s' "${UCI_TOKEN}" ;;
    *chat_id*) printf '%s' "${UCI_CHAT}" ;;
    *enabled*) printf '%s' "${UCI_ENABLED}" ;;
esac
EOF
chmod +x "$BIN"/*
PATH="$BIN:$PATH"
export PATH

# shellcheck disable=SC1090
. "$COMMON"

pass=0
fail=0
check() {
    if [ "${2:-0}" = "1" ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}
reset() { : > "$CALLS"; : > "$COUNT"; : > "$LOGS"; }

# ---------- 一、按告警内容自动挑按钮 ----------
CURL_MODE=ok
UCI_ENABLED=1

reset; send_tg '🔴 <b>网络异常</b>\n外网不可达' HTML
check '网络异常 → 带查状态 + 切换出口' \
    "$(grep -Fq 'refresh_status' "$CALLS" && grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '⚠️ <b>5G 主出口探测超时</b>' HTML
check '5G 主出口探测超时 → 带切换出口' \
    "$(grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '⚠️ <b>5G 已降级</b>' HTML
check '5G 降级 → 带查模组' \
    "$(grep -Fq 'refresh_modem' "$CALLS" && ! grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🔴 <b>5G 热备链路脱网告警</b>' HTML
check '5G 热备脱网 → 带查模组' \
    "$(grep -Fq 'refresh_modem' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🚨 <b>高温警报</b>' HTML
check '高温警报 → 带重新体检' \
    "$(grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🏁 <b>高带宽下载已结束</b>' HTML
check '高带宽结束 → 带重新体检' \
    "$(grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🔴 <b>OpenClash 运行异常</b>' HTML
check 'OpenClash 异常 → 带测节点' \
    "$(grep -Fq 'test_nodes' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🔔 <b>新设备接入局域网</b>' HTML
check '新设备 → 只带查状态（不误带危险按钮）' \
    "$(grep -Fq 'refresh_status' "$CALLS" && ! grep -Fq 'open_uplink_menu' "$CALLS" && ! grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '一条内容无法识别的消息' HTML
check '未知内容 → 默认只带查状态' \
    "$(grep -Fq 'refresh_status' "$CALLS" && ! grep -Fq 'test_nodes' "$CALLS" && echo 1 || echo 0)"

reset; send_tg '🔴 <b>网络异常</b>' HTML '-'
check '显式传 - → 这条不带按钮' \
    "$(grep -Fq 'reply_markup' "$CALLS" && echo 0 || echo 1)"

reset; send_tg '🔴 <b>网络异常</b>' HTML '{"inline_keyboard":[[{"text":"自定义","callback_data":"refresh_direct"}]]}'
check '显式传入的按钮优先于自动挑选' \
    "$(grep -Fq 'refresh_direct' "$CALLS" && ! grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

check '始终带 parse_mode' \
    "$(grep -Fq 'parse_mode=HTML' "$CALLS" && echo 1 || echo 0)"

# ---------- 二、投递校验（curl 成功 != 送达） ----------
reset; send_tg '投递成功' HTML
rc=$?
check '投递成功时返回 0' "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check '投递成功时只发一次请求' "$([ "$(cat "$COUNT")" = "1" ] && echo 1 || echo 0)"
check '投递成功时不写失败日志' "$([ ! -s "$LOGS" ] && echo 1 || echo 0)"

CURL_MODE=fail
reset; send_tg '投递失败' HTML
rc=$?
check '投递失败时返回非 0' "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check '投递失败时重试（共 2 次请求）' "$([ "$(cat "$COUNT")" = "2" ] && echo 1 || echo 0)"
check '投递失败时写 2 条日志' "$([ "$(grep -c '投递失败' "$LOGS")" = "2" ] && echo 1 || echo 0)"

CURL_MODE=fail_once
reset; send_tg '重试成功' HTML
rc=$?
check '首次失败、重试成功 → 返回 0' "$([ "$rc" -eq 0 ] && echo 1 || echo 0)"
check '重试成功后共 2 次请求' "$([ "$(cat "$COUNT")" = "2" ] && echo 1 || echo 0)"
check '重试成功后只写 1 条失败日志' "$([ "$(grep -c '投递失败' "$LOGS")" = "1" ] && echo 1 || echo 0)"

CURL_MODE=ok
UCI_ENABLED=0
reset; send_tg '未配置' HTML
rc=$?
check '机器人未启用时不发请求' "$([ ! -s "$CALLS" ] && echo 1 || echo 0)"
check '机器人未启用时返回非 0' "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check '机器人未启用时留下日志（不再静默）' "$(grep -Fq '未发送' "$LOGS" && echo 1 || echo 0)"

UCI_ENABLED=1
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
