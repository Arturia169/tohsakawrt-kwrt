#!/bin/sh
# 告警带按钮：验证 send_tg 会按正文自动挑选机器人已认识的动作
# 只桩件 curl/uci，不发真实消息
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
CALLS="$TMP/curl.log"
export CALLS

cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$CALLS"
exit 0
EOF
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
case "$*" in
    *token*)   printf '%s' 'test-token' ;;
    *chat_id*) printf '%s' '123456' ;;
    *enabled*) printf '%s' '1' ;;
esac
EOF
chmod +x "$BIN"/*
PATH="$BIN:$PATH"
export PATH

. "$COMMON"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

send_tg '🔴 <b>网络异常</b>\n外网不可达' HTML
check '网络异常 → 带查状态 + 切换出口' \
    "$(grep -Fq 'refresh_status' "$CALLS" && grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

send_tg '⚠️ <b>5G 主出口探测超时</b>' HTML
check '5G 主出口探测超时 → 带切换出口' \
    "$(grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

send_tg '⚠️ <b>5G 已降级</b>' HTML
check '5G 降级 → 带查模组' \
    "$(grep -Fq 'refresh_modem' "$CALLS" && ! grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

send_tg '🔴 <b>5G 热备链路脱网告警</b>' HTML
check '5G 热备脱网 → 带查模组' \
    "$(grep -Fq 'refresh_modem' "$CALLS" && echo 1 || echo 0)"

send_tg '🚨 <b>高温警报</b>' HTML
check '高温警报 → 带重新体检' \
    "$(grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

send_tg '🏁 <b>高带宽下载已结束</b>' HTML
check '高带宽结束 → 带重新体检' \
    "$(grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

send_tg '🔴 <b>OpenClash 运行异常</b>' HTML
check 'OpenClash 异常 → 带测节点' \
    "$(grep -Fq 'test_nodes' "$CALLS" && echo 1 || echo 0)"

send_tg '🔔 <b>新设备接入局域网</b>' HTML
check '新设备 → 只带查状态（不误带危险按钮）' \
    "$(grep -Fq 'refresh_status' "$CALLS" && ! grep -Fq 'open_uplink_menu' "$CALLS" && ! grep -Fq 're_ping' "$CALLS" && echo 1 || echo 0)"

send_tg '一条内容无法识别的消息' HTML
check '未知内容 → 默认只带查状态' \
    "$(grep -Fq 'refresh_status' "$CALLS" && ! grep -Fq 'test_nodes' "$CALLS" && echo 1 || echo 0)"

send_tg '🔴 <b>网络异常</b>' HTML '-'
check '显式传 - → 这条不带按钮' \
    "$(grep -Fq 'reply_markup' "$CALLS" && echo 0 || echo 1)"

send_tg '🔴 <b>网络异常</b>' HTML '{"inline_keyboard":[[{"text":"自定义","callback_data":"refresh_direct"}]]}'
check '显式传入的按钮优先于自动挑选' \
    "$(grep -Fq 'refresh_direct' "$CALLS" && ! grep -Fq 'open_uplink_menu' "$CALLS" && echo 1 || echo 0)"

check '始终带 parse_mode' \
    "$(grep -Fq 'parse_mode=HTML' "$CALLS" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
