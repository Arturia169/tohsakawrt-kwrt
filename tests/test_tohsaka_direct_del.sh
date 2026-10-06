#!/bin/sh
set -u

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsaka-direct" \
            "$ROOT/files/usr/bin/tohsaka-direct"; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
[ -n "${SCRIPT:-}" ] || { echo "cannot locate tohsaka-direct"; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"

LIST="$TMP/direct.list"
RUN_YAML="$TMP/config.yaml"
BAK_YAML="$TMP/backup.yaml"
OUT="$TMP/output"
printf '%s\n' 'example.com' > "$LIST"
for yaml in "$RUN_YAML" "$BAK_YAML"; do
    cat > "$yaml" <<'EOF'
mixed-port: 7890
rules:
  - MATCH,DIRECT
# === TG_DIRECT_RULES_START ===
  - DOMAIN-SUFFIX,example.com,直连
# === TG_DIRECT_RULES_END ===
EOF
done

status=0
TG_DIRECT_LIST="$LIST" TG_DIRECT_RUN_YAML="$RUN_YAML" TG_DIRECT_BAK_YAML="$BAK_YAML" \
    sh "$SCRIPT" del example.com > "$OUT" 2>&1 || status=$?

pass=0
fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1));
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

check 'deleting the only item leaves an empty list' "$( [ "$status" -eq 0 ] && [ ! -s "$LIST" ] && echo 1 || echo 0)"
check 'deleting the only item leaves no temporary file' "$( [ ! -e "${LIST}.tmp" ] && echo 1 || echo 0)"
check 'successful deletion reports DELETED' "$( grep -Fxq 'DELETED:example.com' "$OUT" && echo 1 || echo 0)"
check 'YAML injection block is rewritten from the empty list' "$( grep -Fxq '# === TG_DIRECT_RULES_START ===' "$RUN_YAML" && grep -Fxq '# === TG_DIRECT_RULES_END ===' "$RUN_YAML" && ! grep -Fq 'DOMAIN-SUFFIX,example.com,直连' "$RUN_YAML" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then printf 'RESULT: FAIL\n'; exit 1; fi
printf 'RESULT: ALL PASS\n'
