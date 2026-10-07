#!/bin/sh
# smart 子命令：两条路测速与结论判定（桩件 curl；注意环境变量必须在命令替换之前赋值）
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
S=""
for c in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-clash-direct" "$ROOT/files/usr/bin/tohsakawrt-clash-direct"; do
    [ -f "$c" ] && S="$c" && break
done
S="${CLASH_DIRECT_OVERRIDE:-${S:-}}"
[ -n "${S:-}" ] || { echo "FAIL: 找不到脚本"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"
export TWR_CLASH_MODULE="$TMP/m.yaml" TWR_CLASH_RUNTIME="$TMP/r.yaml" TWR_CLASH_API="http://127.0.0.1:9090"
printf 'rules:\n# === TG_DIRECT_RULES_START ===\n# === TG_DIRECT_RULES_END ===\n' > "$TWR_CLASH_MODULE"
printf 'rules:\n- MATCH,x\n' > "$TWR_CLASH_RUNTIME"
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
case "$*" in
  */proxies/DIRECT/delay*) echo "{\"delay\":${FAKE_DIRECT:-80}}" ;;
  *-x*) echo "${FAKE_PROXY:-0.400000}" ;;
  *) echo 204 ;;
esac
EOF
chmod +x "$BIN"/*; export PATH="$BIN:$PATH"
pass=0; fail=0
check() { if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass+1)); else printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); fi; }

export FAKE_DIRECT=80 FAKE_PROXY=0.400000
OUT="$("$S" smart blog.example.com 2>&1)"
check '直连更快时判定 DIRECT' "$(printf '%s' "$OUT" | grep -q 'VERDICT:DIRECT' && echo 1 || echo 0)"
check '报告两条路的数字' "$(printf '%s' "$OUT" | grep -q 'DIRECT_MS:80' && printf '%s' "$OUT" | grep -q 'PROXY_MS:400' && echo 1 || echo 0)"

export FAKE_DIRECT=500 FAKE_PROXY=0.100000
OUT2="$("$S" smart blog.example.com 2>&1)"
check '代理更快时判定 PROXY' "$(printf '%s' "$OUT2" | grep -q 'VERDICT:PROXY' && echo 1 || echo 0)"

export FAKE_DIRECT=500 FAKE_PROXY=0
OUT3="$("$S" smart blog.example.com 2>&1)"
check '代理测速失败时判定 UNKNOWN（不瞎给建议）' "$(printf '%s' "$OUT3" | grep -q 'VERDICT:UNKNOWN' && echo 1 || echo 0)"

if "$S" smart 'bad;rm' >/dev/null 2>&1; then rc=0; else rc=1; fi
check '非法域名被拒绝' "$([ "$rc" -eq 1 ] && echo 1 || echo 0)"
check '脚本通过 sh -n' "$(sh -n "$S" && echo 1 || echo 0)"
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"; [ "$fail" -eq 0 ] || exit 1
