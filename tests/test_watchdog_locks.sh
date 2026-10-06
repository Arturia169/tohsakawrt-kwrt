#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PAYLOAD=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin" "$ROOT/files/usr/bin"; do
    [ -f "$cand/tohsakawrt-modem-heal" ] && [ -f "$cand/tohsakawrt-service-watch" ] && PAYLOAD="$cand" && break
done
[ -n "${PAYLOAD:-}" ] || { echo "FAIL: 找不到负载"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin" "$TMP/state" "$TMP/net"
printf 'fake modem\n' > "$TMP/atport"
cat > "$TMP/bin/uci" <<'SH'
#!/bin/sh
case "$*" in
  *modem.modem0.network*) echo usb0 ;;
  *openclash*) echo 0 ;;
  *) : ;;
esac
SH
cat > "$TMP/bin/ip" <<'SH'
#!/bin/sh
case "$*" in
  'route get 8.8.8.8') echo '8.8.8.8 via 1.1.1.1 dev eth0' ;;
  'route show default') : ;;
  *) : ;;
esac
SH
cat > "$TMP/bin/mmcli" <<'SH'
#!/bin/sh
case "$*" in
  -L) echo invoked >> "$TEST_MARKER"; echo '/org/freedesktop/ModemManager1/Modem/0' ;;
  *) echo 'state: connected' ;;
esac
SH
cat > "$TMP/bin/date" <<'SH'
#!/bin/sh
echo called >> "$TEST_DATE_MARKER"
case "${1:-}" in +%s) echo 1000000000 ;; *) echo '01-01 00:00:00' ;; esac
SH
cat > "$TMP/bin/logger" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
SH
cat > "$TMP/bin/ping" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" TEST_MARKER="$TMP/mmcli.log" TEST_DATE_MARKER="$TMP/date.log" TEST_LOG="$TMP/logger.log"
HEAL="$PAYLOAD/tohsakawrt-modem-heal"
SERVICE="$PAYLOAD/tohsakawrt-service-watch"
{
    printf '%s\n' '#!/bin/sh'       'format_duration() { echo "${1:-0}s"; }'       'push_bark() { :; }'       'send_tg() { :; }'       'network_get_ipaddr() { :; }'       'network_get_ipaddr6() { :; }'
    sed -e '/^\. \/lib\/functions\/network.sh/d' -e 's|MOBILE_HISTORY_FILE="/root/tohsakawrt-logs/5g-history.log"|MOBILE_HISTORY_FILE="$TWR_TEST_LOG_DIR/5g-history.log"|' -e 's|^mkdir -p /root/tohsakawrt-logs|mkdir -p "$TWR_TEST_LOG_DIR"|' "$SERVICE"
} > "$TMP/service-copy"
chmod +x "$TMP/service-copy"
# Dead-PID lock must be reclaimed and the modem check must run.
mkdir "$TMP/state/tohsakawrt-modem-heal.lock"
echo 99999999 > "$TMP/state/tohsakawrt-modem-heal.lock/pid"
TWR_STATE_DIR="$TMP/state" TWR_HEAL_AT_PORT="$TMP/atport" TWR_HEAL_AT_PORT_FAKE=1 TWR_HEAL_NET_CLASS_DIR="$TMP/net" "$HEAL"
grep -Fxq 'invoked' "$TMP/mmcli.log"
[ ! -d "$TMP/state/tohsakawrt-modem-heal.lock" ]
echo 'PASS: modem-heal reclaims a dead-PID lock and runs'
# Empty PID file lock must be reclaimed by service-watch.
mkdir -p "$TMP/service.lock"
TWR_TEST_LOG_DIR="$TMP/service-logs" TWR_SERVICE_WATCH_LOCK_DIR="$TMP/service.lock" TWR_SERVICE_WATCH_STATE_DIR="$TMP/service-state" "$TMP/service-copy"
grep -Fq 'called' "$TMP/date.log"
[ ! -d "$TMP/service.lock" ]
echo 'PASS: service-watch reclaims a lock with missing PID and runs'
# Current shell PID is live and must block duplicate modem-heal.
: > "$TMP/mmcli.log"
mkdir "$TMP/state/tohsakawrt-modem-heal.lock"
echo "$$" > "$TMP/state/tohsakawrt-modem-heal.lock/pid"
TWR_STATE_DIR="$TMP/state" TWR_HEAL_AT_PORT="$TMP/atport" TWR_HEAL_AT_PORT_FAKE=1 TWR_HEAL_NET_CLASS_DIR="$TMP/net" "$HEAL"
[ ! -s "$TMP/mmcli.log" ]
grep -Fq 'Previous run still active, skip' "$TMP/logger.log"
echo 'PASS: modem-heal skips when lock PID is alive'
