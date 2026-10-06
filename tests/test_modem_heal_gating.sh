#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
# 兼容两种仓库布局：构建仓 devices/mediatek_filogic/files/... 与开发树 files/...
SCRIPT=""
for candidate in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-modem-heal" \
    "$ROOT/files/usr/bin/tohsakawrt-modem-heal" ; do
    [ -f "$candidate" ] && SCRIPT="$candidate" && break
done
SCRIPT="${MODEM_HEAL_SCRIPT_OVERRIDE:-${SCRIPT:-$ROOT/files/usr/bin/tohsakawrt-modem-heal}}"
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
    '-q get tohsakawrt-tgbot.main.modem_data_heal') echo "${TEST_HEAL:-1}" ;;
    '-q get tohsakawrt-tgbot.main.nodata_cards') printf '%s\n' "${TEST_NODATA:-89852 89372}" ;;
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
for cmd in ifup logger sleep send_tg; do
    cat > "$BIN/$cmd" <<EOF
#!/bin/sh
printf '$cmd %s\\n' "\$*" >> "\$CALLS"
EOF
done
cat > "$BIN/sh" <<'EOF'
#!/bin/sh
printf 'sh %s\n' "$*" >> "$CALLS"
case "$*" in
    *modem_at.sh*)
        command="$3"
        case "$command" in
            AT+QCCID)
                if [ "${TEST_AT_FAIL:-0}" = 1 ]; then echo ERROR
                elif [ -n "${TEST_ICCID:-12345}" ]; then echo "+QCCID: \"$TEST_ICCID\""
                else echo ERROR
                fi
                ;;
            AT+CCID)
                if [ "${TEST_CCID:-}" != "" ]; then echo "+CCID: \"$TEST_CCID\""; else echo ERROR; fi
                ;;
        esac
        ;;
esac
EOF
cat > "$BIN/date" <<'EOF'
#!/bin/sh
printf 'date %s\n' "$*" >> "$CALLS"
echo "$TEST_NOW"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

run_once() {
    TEST_ACTIVE_DEV="$1" TEST_NOW="$2" TWR_STATE_DIR="$3" \
    TEST_ICCID="${4-12345}" TEST_HEAL="${5-1}" \
    TEST_NODATA="${6-89852 89372}" TEST_AT_FAIL="${7-0}" TEST_CCID="${8-}" \
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

: > "$CALLS"
mkdir -p "$TMP/state-silent-prefix"
printf '7\n' > "$TMP/state-silent-prefix/tohsakawrt-5g-data.fails"
printf '1\n' > "$TMP/state-silent-prefix/tohsakawrt-5g-data.firstfail"
printf '2\n' > "$TMP/state-silent-prefix/tohsakawrt-5g-data.lastheal"
run_once eth0 7000 "$TMP/state-silent-prefix" 89852
run_once eth0 7060 "$TMP/state-silent-prefix" 89852
check '命中前缀静默且不 ping/动作/TG，只记录一次识别日志' "$( [ "$(grep -c '^ping ' "$CALLS")" -eq 0 ] && [ "$(grep -Ec '^(ifup |sh .* AT\+(QNETDEVCTL|CFUN)|send_tg )' "$CALLS")" -eq 0 ] && [ "$(grep -Fc 'logger -t tohsakawrt-modem-heal 接码卡已识别（ICCID 前缀 89852）：暂停数据自愈' "$CALLS")" -eq 1 ] && echo 1 || echo 0)"
check '静默命中清空三种自愈计数文件' "$( [ ! -e "$TMP/state-silent-prefix/tohsakawrt-5g-data.fails" ] && [ ! -e "$TMP/state-silent-prefix/tohsakawrt-5g-data.firstfail" ] && [ ! -e "$TMP/state-silent-prefix/tohsakawrt-5g-data.lastheal" ] && echo 1 || echo 0)"

: > "$CALLS"
mkdir -p "$TMP/state-silent-disabled"
run_once eth0 7100 "$TMP/state-silent-disabled" 12345 0
check 'modem_data_heal=0 静默不 ping/动作/TG' "$( [ "$(grep -c '^ping ' "$CALLS")" -eq 0 ] && [ "$(grep -Ec '^(ifup |sh .* AT\+(QNETDEVCTL|CFUN)|send_tg )' "$CALLS")" -eq 0 ] && [ "$(grep -Fc 'logger -t tohsakawrt-modem-heal 5G data heal paused by modem_data_heal=0' "$CALLS")" -eq 1 ] && echo 1 || echo 0)"

: > "$CALLS"
mkdir -p "$TMP/state-nodata-ladder"
i=0
while [ "$i" -lt 6 ]; do
    run_once eth0 $((8000 + i * 70)) "$TMP/state-nodata-ladder" 12345
    i=$((i + 1))
done
check '不命中仍按 Stage 1 ifup、Stage 2 QNETDEVCTL、Stage 3 CFUN' "$(grep -q '^ifup 5Ga$' "$CALLS" && grep -q 'AT+QNETDEVCTL=1,1,1' "$CALLS" && grep -q 'AT+CFUN=0' "$CALLS" && grep -q 'AT+CFUN=1' "$CALLS" && echo 1 || echo 0)"

: > "$CALLS"
mkdir -p "$TMP/state-empty-iccid"
i=0
while [ "$i" -lt 6 ]; do
    run_once eth0 $((9000 + i * 70)) "$TMP/state-empty-iccid" '' 1 '89852 89372' 1
    i=$((i + 1))
done
check 'ICCID QCCID/CCID 都读失败时按数据卡继续原阶梯' "$(grep -q 'ICCID 读取失败，按数据卡处理并继续数据自愈' "$CALLS" && grep -q '^ifup 5Ga$' "$CALLS" && grep -q 'AT+QNETDEVCTL=1,1,1' "$CALLS" && grep -q 'AT+CFUN=0' "$CALLS" && echo 1 || echo 0)"

: > "$CALLS"
mkdir -p "$TMP/state-alert-throttle"
i=0
while [ "$i" -lt 6 ]; do
    run_once eth0 $((10000 + i * 70)) "$TMP/state-alert-throttle" 12345
    i=$((i + 1))
done
run_once eth0 10420 "$TMP/state-alert-throttle" 12345
check '热备 Stage 3 两次触发间隔小于 1800 秒只告警一次' "$( [ "$(grep -Fc 'send_tg ' "$CALLS")" -eq 1 ] && echo 1 || echo 0)"
run_once eth0 12221 "$TMP/state-alert-throttle" 12345
check '热备 Stage 3 超过 1800 秒后允许第二次告警' "$( [ "$(grep -Fc 'send_tg ' "$CALLS")" -eq 2 ] && echo 1 || echo 0)"

if [ "${MUTATION_CHILD:-0}" != 1 ]; then
    mutate_source() {
        python3 - "$1" "$2" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
op = sys.argv[2]
s = path.read_text()
before = s
if op == "prefix-always-match":
    old = 'case "$iccid" in\n                "$candidate"*) nodata_prefix="$candidate"; break ;;'
    new = 'case "$iccid" in\n                *) nodata_prefix="$candidate"; break ;;'
elif op == "alert-always-pass":
    old = '[ "$((now - last_alert))" -ge 1800 ]'
    new = '[ "$((now - last_alert))" -ge 0 ]'
else:
    raise AssertionError(f"unknown mutation: {op}")
assert old in s, f"mutation target missing: {op}"
if op == "alert-always-pass":
    assert s.count(old) >= 2, "expected separate primary and standby cooldown checks"
    index = s.rfind(old)
    s = s[:index] + new + s[index + len(old):]
else:
    s = s.replace(old, new, 1)
assert s != before, f"mutation did not change source: {op}"
path.write_text(s)
print(f"已注入 {op}")
PY
    }
    for op in prefix-always-match alert-always-pass; do
        mutated="$TMP/modem-heal-$op"
        cp "$SCRIPT" "$mutated"
        mutate_source "$mutated" "$op"
        MUTATION_CHILD=1 MODEM_HEAL_SCRIPT_OVERRIDE="$mutated" /bin/sh "$0" > "$TMP/mutation-$op.out" 2>&1
        mutation_status=$?
        if [ "$op" = prefix-always-match ]; then expected='FAIL: 不命中仍按 Stage 1 ifup、Stage 2 QNETDEVCTL、Stage 3 CFUN';
        else expected='FAIL: 热备 Stage 3 两次触发间隔小于 1800 秒只告警一次'; fi
        check "变异 $op 精确触发预期失败" "$( [ "$mutation_status" -ne 0 ] && grep -Fxq "$expected" "$TMP/mutation-$op.out" && echo 1 || echo 0)"
        cat "$TMP/mutation-$op.out" | grep -E '已注入|FAIL:|PASS=' | tail -n 12 >> "$CALLS"
    done
fi

printf '%s\n' '--- calls log: primary uplink guard ---'
grep -E 'uplink_is_modem: 1|ping failed|skipped:|ifup|AT\+|send_tg' "$TMP/calls-primary.log" | head -n 24
printf '%s\n' '--- calls log: 3-failure standby ---'
grep -E 'ping failed|CFUN' "$TMP/calls-standby3.log"
printf '%s\n' '--- calls log: standby RF reset ---'
grep -E 'uplink_is_modem: 0|ping failed|CFUN' "$CALLS" | tail -n 20
printf '%s\n' '--- mutation child output (预期失败，[MUT] 前缀 = 子运行，不是主结果) ---'
grep -E '已注入|FAIL:|PASS=' "$CALLS" | sed 's/^/[MUT] /' | tail -n 24
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then printf 'RESULT: FAIL\n'; exit 1; fi
printf 'RESULT: ALL PASS\n'
exit 0
