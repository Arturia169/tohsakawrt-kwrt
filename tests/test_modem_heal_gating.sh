#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-modem-heal"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/net/usb0" "$TMP/share"
CALLS="$TMP/calls.log"
AT_PORT="$TMP/ttyUSB2"
AT_SCRIPT="$TMP/share/modem_at.sh"
: > "$AT_PORT"
cat > "$AT_SCRIPT" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$AT_SCRIPT"
export CALLS

cat > "$BIN/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$CALLS"
case "$*" in
    'route get 8.8.8.8') echo "8.8.8.8 dev ${TEST_ACTIVE_DEV:-eth0} src 192.168.225.43" ;;
    '-4 addr show usb0') echo '2: usb0 inet 192.168.225.43/24 scope global usb0' ;;
esac
EOF
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$CALLS"
case "$*" in
    '-q get modem.modem0.network') echo usb0 ;;
    '-q get sms_manager.@sms_manager[0].'*) echo /org/freedesktop/ModemManager1/Modem/0 ;;
esac
EOF
cat > "$BIN/ping" <<'EOF'
#!/bin/sh
printf 'ping %s\n' "$*" >> "$CALLS"
exit 1
EOF
cat > "$BIN/mmcli" <<'EOF'
#!/bin/sh
printf 'mmcli %s\n' "$*" >> "$CALLS"
case "$*" in
    -L) echo '/org/freedesktop/ModemManager1/Modem/0 [Quectel] RM500Q' ;;
    '-m 0') echo 'state: connected' ;;
esac
EOF
for cmd in ifup logger sh sleep send_tg; do
    cat > "$BIN/$cmd" <<EOF
#!/bin/sh
printf '$cmd %s\\n' "\$*" >> "\$CALLS"
EOF
done
cat > "$BIN/date" <<'EOF'
#!/bin/sh
printf 'date %s\n' "$*" >> "$CALLS"
echo "$TEST_NOW"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

run_once() {
    TEST_ACTIVE_DEV="$1" TEST_NOW="$2" TWR_STATE_DIR="$3" \
    TWR_HEAL_NET_CLASS_DIR="$TMP/net" TWR_HEAL_AT_PORT="$AT_PORT" \
    TWR_HEAL_AT_SCRIPT="$AT_SCRIPT" TWR_HEAL_AT_PORT_FAKE=1 \
    "$SCRIPT" --verbose >> "$CALLS" 2>&1
}

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

mkdir -p "$TMP/state-primary" "$TMP/state-standby3" "$TMP/state-standby6"
: > "$CALLS"
i=0
while [ "$i" -lt 5 ]; do
    run_once usb0 $((1000 + i * 70)) "$TMP/state-primary"
    i=$((i + 1))
done
cp "$CALLS" "$TMP/calls-primary.log"
check 'UPLINK_IS_MODEM=1 连续失败 5 次无 ifup/AT+QNETDEVCTL/AT+CFUN' "$(grep -q 'uplink_is_modem: 1' "$CALLS" && ! grep -Eq '^(ifup |sh .*AT\+(QNETDEVCTL|CFUN))' "$CALLS" && echo 1 || echo 0)"
check '主出口连续失败告警限流为一条' "$( [ "$(grep -Fc 'send_tg ' "$CALLS")" -eq 1 ] && grep -q '5G 正在承载主出口，探测超时，已按策略不做动作' "$CALLS" && echo 1 || echo 0)"

: > "$CALLS"
i=0
while [ "$i" -lt 3 ]; do
    run_once eth0 $((3000 + i * 70)) "$TMP/state-standby3"
    i=$((i + 1))
done
cp "$CALLS" "$TMP/calls-standby3.log"
check 'UPLINK_IS_MODEM=0 失败 3 次未触发 AT+CFUN' "$(grep -q 'uplink_is_modem: 0' "$CALLS" && ! grep -q 'AT+CFUN' "$CALLS" && echo 1 || echo 0)"

: > "$CALLS"
i=0
while [ "$i" -lt 6 ]; do
    run_once eth0 $((5000 + i * 60)) "$TMP/state-standby6"
    i=$((i + 1))
done
check '失败 6 次且跨度 300 秒时 AT+CFUN=0/1 各出现一次' "$( [ "$(grep -Ec '^sh .* AT\+CFUN=0$' "$CALLS")" -eq 1 ] && [ "$(grep -Ec '^sh .* AT\+CFUN=1$' "$CALLS")" -eq 1 ] && echo 1 || echo 0)"
check '自愈脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
printf '%s\n' '--- calls log: primary uplink guard ---'
grep -E 'uplink_is_modem: 1|ping failed|skipped:|ifup|AT\+|send_tg' "$TMP/calls-primary.log" | head -n 24
printf '%s\n' '--- calls log: 3-failure standby ---'
grep -E 'ping failed|CFUN' "$TMP/calls-standby3.log"
printf '%s\n' '--- calls log: standby RF reset ---'
grep -E 'uplink_is_modem: 0|ping failed|CFUN' "$CALLS" | tail -n 20
if [ "$fail" -ne 0 ]; then exit 1; fi
