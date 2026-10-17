#!/bin/sh
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-wallpaper" \
    "$ROOT/files/usr/bin/tohsakawrt-wallpaper" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${WALLPAPER_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-wallpaper"; exit 1; }
TMP="$(mktemp -d)"
export TMP
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"
export CALLS="$TMP/wget.log" UCI_LOG="$TMP/uci.log" LOGGER_LOG="$TMP/logger.log"
export BG_DIR="$TMP/background" STATE_FILE="$TMP/state.url" ARGON_CONFIG="$TMP/argon"
export PATH="$BIN:$PATH"
: > "$CALLS"; : > "$UCI_LOG"; : > "$LOGGER_LOG"; : > "$ARGON_CONFIG"
cat > "$BIN/wget" <<'STUB'
#!/bin/sh
printf 'wget %s\n' "$*" >> "$CALLS"
case "$*" in
    *HPImageArchive*)
        [ -f "$TMP/api_empty" ] || printf '%s\n' '{"images":[{"url":"/th?id=OHR.Test_UHD.jpg&pid=hp"}]}'
        ;;
    *)
        target=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "-O" ]; then shift; target="$1"; fi
            shift
        done
        if [ -f "$TMP/api_fail" ]; then printf '0123456789' > "$target"
        elif [ -f "$TMP/api_short" ]; then printf '\377\330\377' > "$target"; dd if=/dev/zero bs=1 count=7 2>/dev/null >> "$target"
        elif [ -f "$TMP/api_nomagic" ]; then dd if=/dev/zero bs=1 count=300000 2>/dev/null > "$target"
        else printf '\377\330\377' > "$target"; dd if=/dev/zero bs=1 count=299997 2>/dev/null >> "$target"; fi
        ;;
esac
STUB
cat > "$BIN/jsonfilter" <<'STUB'
#!/bin/sh
body="$(cat)"
[ -n "$body" ] && printf '%s\n' '/th?id=OHR.Test_UHD.jpg&pid=hp'
STUB
cat > "$BIN/uci" <<'STUB'
#!/bin/sh
printf 'uci %s\n' "$*" >> "$UCI_LOG"
case "$*" in
    *'get argon.@global[0].online_wallpaper'*)
        n="$(grep -c 'get argon.@global\[0\].online_wallpaper' "$UCI_LOG")"
        if [ "$n" -eq 1 ]; then echo bing; else echo none; fi
        ;;
esac
exit 0
STUB
cat > "$BIN/logger" <<'STUB'
#!/bin/sh
printf 'logger %s\n' "$*" >> "$LOGGER_LOG"
exit 0
STUB
chmod +x "$BIN"/*
pass=0
assert() { [ "$1" -eq 1 ] || { echo "FAIL: $2"; exit 1; }; pass=$((pass + 1)); }
URL='https://www.bing.com/th?id=OHR.Test_UHD.jpg&pid=hp'
# Case 1: fresh install
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
assert "$([ "$rc" -eq 0 ] && echo 1 || echo 0)" 'fresh run exit status'
assert "$([ "$OUT" = "updated: $URL" ] && echo 1 || echo 0)" 'fresh run output'
assert "$([ -f "$BG_DIR/bing-daily.jpg" ] && echo 1 || echo 0)" 'image installed'
assert "$([ "$(wc -c < "$BG_DIR/bing-daily.jpg" | tr -d '[:space:]')" = 300000 ] && echo 1 || echo 0)" 'image size'
assert "$(head -c 3 "$BG_DIR/bing-daily.jpg" | od -An -tx1 | tr -d ' \n' | grep -qi '^ffd8ff$' && echo 1 || echo 0)" 'JPEG magic'
assert "$([ "$(cat "$STATE_FILE")" = "$URL" ] && echo 1 || echo 0)" 'state URL'
assert "$(grep -q 'set argon.@global\[0\].online_wallpaper=none' "$UCI_LOG" && echo 1 || echo 0)" 'uci set local wallpaper'
# Case 2: unchanged; only API wget call
before="$(wc -l < "$CALLS" | tr -d '[:space:]')"
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
after="$(wc -l < "$CALLS" | tr -d '[:space:]')"
assert "$([ "$rc" -eq 0 ] && [ "$OUT" = unchanged ] && echo 1 || echo 0)" 'unchanged status and output'
assert "$([ $((after - before)) -eq 1 ] && echo 1 || echo 0)" 'unchanged performs API only'
# Case 3: empty API preserves image and state
md5="$(md5sum "$BG_DIR/bing-daily.jpg" | awk '{print $1}')"; state="$(cat "$STATE_FILE")"; : > "$TMP/api_empty"
if OUT="$("$SCRIPT" 2>&1)"; then rc=0; else rc=$?; fi
rm -f "$TMP/api_empty"
assert "$([ "$rc" -eq 1 ] && echo 1 || echo 0)" 'empty API exits failure'
assert "$(printf '%s' "$OUT" | grep -q failed && echo 1 || echo 0)" 'empty API failure output'
assert "$([ "$(md5sum "$BG_DIR/bing-daily.jpg" | awk '{print $1}')" = "$md5" ] && [ "$(cat "$STATE_FILE")" = "$state" ] && echo 1 || echo 0)" 'empty API preserves files'
# Case 4: invalid image preserves old file and removes tmp
: > "$TMP/api_fail"
if OUT="$("$SCRIPT" -f 2>&1)"; then rc=0; else rc=$?; fi
rm -f "$TMP/api_fail"
assert "$([ "$rc" -eq 1 ] && echo 1 || echo 0)" 'bad payload exits failure'
assert "$([ "$(md5sum "$BG_DIR/bing-daily.jpg" | awk '{print $1}')" = "$md5" ] && [ ! -e "$BG_DIR/.bing-daily.jpg.tmp" ] && echo 1 || echo 0)" 'bad payload preserves image and removes temp'
# Case 5: force fetches API and image
before="$(wc -l < "$CALLS" | tr -d '[:space:]')"
if OUT="$("$SCRIPT" -f 2>&1)"; then rc=0; else rc=$?; fi
after="$(wc -l < "$CALLS" | tr -d '[:space:]')"
assert "$([ "$rc" -eq 0 ] && [ $((after - before)) -eq 2 ] && echo 1 || echo 0)" 'force downloads image'
# Case 6: prune only bing-prefixed old image
: > "$BG_DIR/bing-20260101.jpg"; : > "$BG_DIR/README.md"
"$SCRIPT" -f >/dev/null 2>&1 || { echo 'FAIL: prune run'; exit 1; }
assert "$([ ! -e "$BG_DIR/bing-20260101.jpg" ] && [ -f "$BG_DIR/README.md" ] && echo 1 || echo 0)" 'prune old bing image and retain README'
# Case 7: 头合法但体积过小的截断图必须被拒（覆盖大小校验分支）
: > "$TMP/api_short"
if OUT="$("$SCRIPT" -f 2>&1)"; then rc=0; else rc=$?; fi
rm -f "$TMP/api_short"
assert "$([ "$rc" -eq 1 ] && [ "$(md5sum "$BG_DIR/bing-daily.jpg" | awk '{print $1}')" = "$md5" ] && [ ! -e "$BG_DIR/.bing-daily.jpg.tmp" ] && echo 1 || echo 0)" 'truncated image rejected and previous kept'
# Case 8: 体积达标但幻数不对（全零 300KB）必须被拒（覆盖幻数校验分支）
: > "$TMP/api_nomagic"
if OUT="$("$SCRIPT" -f 2>&1)"; then rc=0; else rc=$?; fi
rm -f "$TMP/api_nomagic"
assert "$([ "$rc" -eq 1 ] && [ "$(md5sum "$BG_DIR/bing-daily.jpg" | awk '{print $1}')" = "$md5" ] && echo 1 || echo 0)" 'non-JPEG payload rejected and previous kept'
printf 'PASS=%s FAIL=0\n' "$pass"
