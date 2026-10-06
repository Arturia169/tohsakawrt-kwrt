#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# 兼容两种仓库布局：构建仓 devices/mediatek_filogic/files/... 与开发树 files/...
SCRIPT=""
for candidate in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-uplink" \
    "$ROOT/files/usr/bin/tohsakawrt-uplink" ; do
    [ -f "$candidate" ] && SCRIPT="$candidate" && break
done
SCRIPT="${UPLINK_SCRIPT_OVERRIDE:-${SCRIPT:-$ROOT/files/usr/bin/tohsakawrt-uplink}}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir -p "$BIN"
CALLS="$TMP/calls.log"
export CALLS

cat > "$BIN/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$CALLS"
case "$*" in
    'route get 8.8.8.8')
        route_dev="${TEST_ROUTE_GET_DEV:-eth0}"
        if [ "$route_dev" = towan ] || [ "$route_dev" = to5g ]; then
            gets="$(grep -c '^ip route get 8.8.8.8$' "$CALLS")"
            if [ "$gets" -gt 1 ]; then
                [ "$route_dev" = towan ] && route_dev=eth0 || route_dev=usb0
            else
                [ "$route_dev" = towan ] && route_dev=usb0 || route_dev=eth0
            fi
        fi
        echo "8.8.8.8 via 192.168.225.1 dev $route_dev src 192.168.225.43"
        ;;
    'route show default dev usb0') [ "${TEST_USB_GW:-1}" = 1 ] && echo 'default via 192.168.225.1 dev usb0 proto static metric 20' ;;
    'route show default dev eth0') [ "${TEST_ETH_GW:-1}" = 1 ] && echo 'default via 192.168.1.1 dev eth0 proto static metric 10' ;;
    '-4 addr show usb0') [ "${TEST_USB_IP:-1}" = 1 ] && echo '2: usb0 inet 192.168.225.43/24 scope global usb0' ;;
esac
EOF
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$CALLS"
case "$*" in
    '-q get network.wan.metric') echo 20 ;;
    '-q get network.5Ga.metric') echo 5 ;;
esac
EOF
for cmd in ubus logger; do
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
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

: > "$CALLS"
TEST_ROUTE_GET_DEV=to5g TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" 5g > "$TMP/switch5g.out" 2>&1
cp "$CALLS" "$TMP/calls-5g.log"
check '切换过程没有 ubus call network reload' "$(if grep -q 'ubus call network reload' "$CALLS"; then echo 0; else echo 1; fi)"
check '切 5G 添加 metric 1 优先路由且未 ifup/ifdown' "$(grep -Fq 'ip route replace default via 192.168.225.1 dev usb0 metric 1' "$CALLS" && ! grep -Eq '(^| )(ifup|ifdown)( |$)' "$CALLS" && echo 1 || echo 0)"
check 'normalize_metrics 归位 metric 时提交 uci（否则是空操作）' \
    "$(grep -Fq 'uci commit network' "$TMP/calls-5g.log" && echo 1 || echo 0)"

: > "$CALLS"
TEST_ROUTE_GET_DEV=towan TEST_USB_IP=1 TEST_USB_GW=1 "$SCRIPT" wan > "$TMP/switchwan.out" 2>&1
cp "$CALLS" "$TMP/calls-wan.log"
check '切回 WAN 删除 5G metric 1 路由并校验 eth0' "$(grep -Fq 'ip route del default via 192.168.225.1 dev usb0 metric 1' "$CALLS" && grep -Fq 'ip route get 8.8.8.8' "$CALLS" && grep -q SUCCESS_WAN "$TMP/switchwan.out" && echo 1 || echo 0)"

: > "$CALLS"
if TEST_ROUTE_GET_DEV=eth0 TEST_USB_IP=0 TEST_USB_GW=1 "$SCRIPT" 5g > "$TMP/noip.out" 2>&1; then noip_failed=0; else noip_failed=1; fi
check 'usb0 无 IP 时非零退出且打印中文原因' "$([ "$noip_failed" -eq 1 ] && grep -q '未获取到 IP' "$TMP/noip.out" && echo 1 || echo 0)"
check 'usb0 无 IP 时没有路由变更' "$(grep -Eq '^ip route (replace|del) ' "$CALLS" && echo 0 || echo 1)"
check '切换脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

: > "$CALLS"
if TEST_ROUTE_GET_DEV=usb0 TEST_ETH_GW=0 TEST_USB_GW=1 "$SCRIPT" wan > "$TMP/no-wan-gateway.out" 2>&1; then no_wan_failed=0; else no_wan_failed=1; fi
check 'WAN 无默认网关时返回 ERROR_SWITCH_FAILED' "$([ "$no_wan_failed" -eq 1 ] && grep -Fxq 'ERROR_SWITCH_FAILED' "$TMP/no-wan-gateway.out" && echo 1 || echo 0)"
check 'WAN 无默认网关时不删除任何 5G 默认路由' "$(grep -Eq '^ip route del default .* dev usb0 ' "$CALLS" && echo 0 || echo 1)"

: > "$CALLS"
if TEST_ROUTE_GET_DEV=usb0 TEST_ETH_GW=1 TEST_USB_GW=1 "$SCRIPT" wan > "$TMP/rollback.out" 2>&1; then rollback_failed=0; else rollback_failed=1; fi
check 'WAN 切换校验失败时返回 ERROR_SWITCH_FAILED' "$([ "$rollback_failed" -eq 1 ] && grep -Fxq 'ERROR_SWITCH_FAILED' "$TMP/rollback.out" && echo 1 || echo 0)"
check 'WAN 切换校验失败时恢复 5G metric 1 默认路由' "$(grep -Fq 'ip route replace default via 192.168.225.1 dev usb0 metric 1' "$CALLS" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
printf '%s\n' '--- calls log: 5G switch ---'
cat "$TMP/calls-5g.log"
printf '%s\n' '--- calls log: WAN switch ---'
cat "$TMP/calls-wan.log"
if [ "$fail" -ne 0 ]; then exit 1; fi
