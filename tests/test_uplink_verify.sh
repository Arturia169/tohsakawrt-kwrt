#!/bin/sh
# 出口切换加固的两条新行为：
#   ① 切换后做真实连通性探测，失败必须回滚（不能停在死线路上）
#   ② 记录"期望出口"并支持 reconcile 对账自愈（实际≠期望时自动改回，且 uci 可关）
# 全程桩件 ip/ping/curl/uci/logger，不触碰真实网络
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT=""
for candidate in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-uplink" \
    "$ROOT/files/usr/bin/tohsakawrt-uplink" ; do
    [ -f "$candidate" ] && SCRIPT="$candidate" && break
done
SCRIPT="${UPLINK_SCRIPT_OVERRIDE:-${SCRIPT:-$ROOT/files/usr/bin/tohsakawrt-uplink}}"
[ -f "$SCRIPT" ] || { echo "FAIL: 找不到 tohsakawrt-uplink"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir -p "$BIN"
CALLS="$TMP/calls.log"
export CALLS
export TOHSAKA_UPLINK_DESIRED="$TMP/uplink.desired"
export TOHSAKA_UPLINK_LOCK="$TMP/uplink.lock"
export TOHSAKA_UPLINK_FALLBACK="$TMP/uplink_fallback"
export TOHSAKA_UPLINK_RECONCILE_FAIL="$TMP/uplink_reconcile_failed"

# 桩件：ip —— 用 TEST_ROUTE_GET_DEV 控制"当前出口"，并可切换"切换后"的取值
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$CALLS"
case "$*" in
    'route get 8.8.8.8')
        dev="${TEST_ROUTE_GET_DEV:-eth0}"
        # towan/to5g：按"路由表是否已被改动"决定当前出口（比按调用次数翻转更贴近真实语义，
        # 因为 reconcile 内部会额外调用一次 get_active_uplink）
        case "$dev" in
            to5g)
                if grep -q '^ip route replace default via 192.168.225.1 dev usb0 metric 1$' "$CALLS"; then
                    dev=usb0
                else
                    dev=eth0
                fi
                ;;
            towan)
                if grep -q '^ip route del default via 192.168.225.1 dev usb0 metric 1$' "$CALLS"; then
                    dev=eth0
                else
                    dev=usb0
                fi
                ;;
        esac
        echo "8.8.8.8 via 192.168.225.1 dev $dev src 192.168.225.43"
        ;;
    'route show default dev usb0') [ "${TEST_USB_GW:-1}" = 1 ] && echo 'default via 192.168.225.1 dev usb0 proto static metric 20' ;;
    'route show default dev eth0') [ "${TEST_ETH_GW:-1}" = 1 ] && echo 'default via 192.168.1.1 dev eth0 proto static metric 10' ;;
    '-4 addr show usb0') [ "${TEST_USB_IP:-1}" = 1 ] && echo '2: usb0 inet 192.168.225.43/24 scope global usb0' ;;
    '-4 addr show eth0') [ "${TEST_ETH_IP:-1}" = 1 ] && echo '3: eth0 inet 192.168.1.2/24 brd 192.168.1.255 scope global eth0' ;;
esac
EOF

# 桩件：ping / curl —— TEST_PROBE_FAIL=1 时全部失败（模拟"切到死线路"）
cat > "$BIN/ping" <<'EOF'
#!/bin/sh
printf 'ping %s\n' "$*" >> "$CALLS"
[ "${TEST_PROBE_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$CALLS"
[ "${TEST_PROBE_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF

# 桩件：uci —— uplink_enforce 由 TEST_ENFORCE 控制
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$CALLS"
case "$*" in
    *uplink_enforce*) printf '%s' "${TEST_ENFORCE:-1}" ;;
    '-q get network.wan.metric') echo 10 ;;
    '-q get network.5Ga.metric') echo 20 ;;
esac
EOF
for cmd in logger ubus; do
    cat > "$BIN/$cmd" <<EOF
#!/bin/sh
printf '$cmd %s\\n' "\$*" >> "\$CALLS"
EOF
done
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

# ---------- ① 探测失败必须回滚：切 WAN ----------
: > "$CALLS"
rm -f "$TOHSAKA_UPLINK_DESIRED"
if TEST_ROUTE_GET_DEV=towan TEST_USB_IP=1 TEST_USB_GW=1 TEST_PROBE_FAIL=1 \
     "$SCRIPT" wan > "$TMP/wan-probe-fail.out" 2>&1; then rc=0; else rc=1; fi
check '切 WAN 探测失败时非零退出并给出原因' \
    "$([ "$rc" -eq 1 ] && grep -Fq 'ERROR_UNVERIFIED_WAN' "$TMP/wan-probe-fail.out" && echo 1 || echo 0)"
check '切 WAN 探测失败时恢复 5G 优先路由（回滚）' \
    "$(grep -Fq 'ip route replace default via 192.168.225.1 dev usb0 metric 1' "$CALLS" && echo 1 || echo 0)"
check '探测失败时不写"期望出口"' \
    "$([ ! -f "$TOHSAKA_UPLINK_DESIRED" ] && echo 1 || echo 0)"
check '探测确实走了两个独立目标（ping + curl）' \
    "$(grep -q '^ping ' "$CALLS" && grep -q '^curl ' "$CALLS" && echo 1 || echo 0)"

# ---------- ① 探测失败必须回滚：切 5G ----------
: > "$CALLS"
if TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 TEST_PROBE_FAIL=1 \
     "$SCRIPT" 5g > "$TMP/5g-probe-fail.out" 2>&1; then rc=0; else rc=1; fi
check '切 5G 探测失败时非零退出并给出原因' \
    "$([ "$rc" -eq 1 ] && grep -Fq 'ERROR_UNVERIFIED_5G' "$TMP/5g-probe-fail.out" && echo 1 || echo 0)"
check '切 5G 探测失败时撤销刚加的优先路由' \
    "$(grep -Fq 'ip route del default via 192.168.225.1 dev usb0 metric 1' "$CALLS" && echo 1 || echo 0)"

# ---------- 探测成功才写"期望出口" ----------
: > "$CALLS"
rm -f "$TOHSAKA_UPLINK_DESIRED"
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" 5g > "$TMP/5g-ok.out" 2>&1
check '切 5G 探测成功时返回 SUCCESS_5G' \
    "$(grep -Fq 'SUCCESS_5G' "$TMP/5g-ok.out" && echo 1 || echo 0)"
check '切换成功后记录期望出口=5g（供重启后自愈）' \
    "$([ "$(cat "$TOHSAKA_UPLINK_DESIRED" 2>/dev/null)" = "5g" ] && echo 1 || echo 0)"

# ---------- ② reconcile：一致时不动；不一致时改回；uci 可关 ----------
: > "$CALLS"
printf '5g\n' > "$TOHSAKA_UPLINK_DESIRED"
TEST_ROUTE_GET_DEV=usb0 "$SCRIPT" reconcile > "$TMP/rec-same.out" 2>&1
check 'reconcile：实际与期望一致时不做任何路由变更' \
    "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"

: > "$CALLS"
printf '5g\n' > "$TOHSAKA_UPLINK_DESIRED"
# to5g：第一次 route get 返回 eth0（表示当前是 WAN），切换后返回 usb0（表示切换生效）
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" reconcile > "$TMP/rec-drift.out" 2>&1
check 'reconcile：实际是 WAN 而期望 5G 时自动改回 5G' \
    "$(grep -Fq 'ip route replace default via 192.168.225.1 dev usb0 metric 1' "$CALLS" \
        && grep -Fq 'SUCCESS_5G' "$TMP/rec-drift.out" && echo 1 || echo 0)"

: > "$CALLS"
printf 'wan\n' > "$TOHSAKA_UPLINK_DESIRED"
TEST_ROUTE_GET_DEV=usb0 TEST_ENFORCE=0 "$SCRIPT" reconcile > "$TMP/rec-off.out" 2>&1
check 'reconcile：uplink_enforce=0 时不自动改（尊重用户关闭）' \
    "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"

# ---------- 期望出口文件缺失时不得干预 ----------
: > "$CALLS"
rm -f "$TOHSAKA_UPLINK_DESIRED"
TEST_ROUTE_GET_DEV=eth0 "$SCRIPT" reconcile > "$TMP/rec-none.out" 2>&1
check 'reconcile：没有期望记录时完全不干预' \
    "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"

check '脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

# ---------- 第 5 项：菜单预检 check <wan|5g> ----------
: > "$CALLS"
out="$(TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" check 5g 2>&1)"
check 'check 5g：有 IP 且网关可达 → READY' "$([ "$out" = "READY" ] && echo 1 || echo 0)"

: > "$CALLS"
out="$(TEST_USB_IP=0 "$SCRIPT" check 5g 2>&1)"
check 'check 5g：未取得 IP → NO_IP' "$([ "$out" = "NO_IP" ] && echo 1 || echo 0)"

: > "$CALLS"
out="$(TEST_USB_IP=1 TEST_USB_GW=0 "$SCRIPT" check 5g 2>&1)"
check 'check 5g：无默认网关 → NO_GATEWAY' "$([ "$out" = "NO_GATEWAY" ] && echo 1 || echo 0)"

: > "$CALLS"
out="$(TEST_ETH_IP=1 TEST_ETH_GW=1 TEST_PROBE_FAIL=1 "$SCRIPT" check wan 2>&1)"
check 'check wan：网关 ping 不通 → UNREACHABLE' "$([ "$out" = "UNREACHABLE" ] && echo 1 || echo 0)"

: > "$CALLS"
out="$("$SCRIPT" check 5g 2>&1)"
check 'check 不产生任何路由变更（只读预检）' \
    "$(grep -Eq '^ip route (replace|del|add) ' "$CALLS" && echo 0 || echo 1)"

# ---------- 第 4 项：临时回落（不改期望值）+ 回落期间不纠偏 + resume + 失败冷却 ----------
: > "$CALLS"
printf '5g\n' > "$TOHSAKA_UPLINK_DESIRED"
rm -f "$TOHSAKA_UPLINK_FALLBACK" "$TOHSAKA_UPLINK_RECONCILE_FAIL"
TEST_ROUTE_GET_DEV=towan TEST_USB_IP=1 TEST_USB_GW=1 TOHSAKA_UPLINK_KEEP_DESIRED=1 \
    "$SCRIPT" wan > "$TMP/fb.out" 2>&1
check '临时回落切到宽带成功' "$(grep -Fq 'SUCCESS_WAN' "$TMP/fb.out" && echo 1 || echo 0)"
check '临时回落不覆盖期望出口（仍是 5g）' \
    "$([ "$(cat "$TOHSAKA_UPLINK_DESIRED" 2>/dev/null)" = "5g" ] && echo 1 || echo 0)"
check '临时回落会写下回落标记' "$([ -f "$TOHSAKA_UPLINK_FALLBACK" ] && echo 1 || echo 0)"

: > "$CALLS"
TEST_ROUTE_GET_DEV=eth0 TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" reconcile > "$TMP/fb-rec.out" 2>&1
check '回落期间 reconcile 不纠偏（否则会来回切网）' \
    "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"

: > "$CALLS"
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" resume > "$TMP/fb-resume.out" 2>&1
check 'resume：清掉回落标记并切回期望出口 5g' \
    "$(grep -Fq 'SUCCESS_5G' "$TMP/fb-resume.out" && [ ! -f "$TOHSAKA_UPLINK_FALLBACK" ] && echo 1 || echo 0)"

: > "$CALLS"
rm -f "$TOHSAKA_UPLINK_FALLBACK"
TEST_ROUTE_GET_DEV=usb0 "$SCRIPT" resume > "$TMP/fb-noop.out" 2>&1
check 'resume：没有回落标记时什么都不做' \
    "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"

: > "$CALLS"
printf '5g\n' > "$TOHSAKA_UPLINK_DESIRED"
rm -f "$TOHSAKA_UPLINK_FALLBACK" "$TOHSAKA_UPLINK_RECONCILE_FAIL"
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=0 TEST_USB_GW=1 "$SCRIPT" reconcile > "$TMP/rec-cd1.out" 2>&1
check 'reconcile 失败时记下冷却时间戳' "$([ -f "$TOHSAKA_UPLINK_RECONCILE_FAIL" ] && echo 1 || echo 0)"
: > "$CALLS"
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" reconcile > "$TMP/rec-cd2.out" 2>&1
check 'reconcile 冷却期内不再重试（避免每分钟抖动）' \
    "$(grep -q 'addr show' "$CALLS" && echo 0 || echo 1)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
