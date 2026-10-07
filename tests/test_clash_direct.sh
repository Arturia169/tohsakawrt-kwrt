#!/bin/sh
# 规则管理脚本：加入/移除直连域名，两处文件都要改，并触发热重载
# 全程用临时文件 + 桩件 curl，不碰真实 Clash 配置
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT=""
for cand in \
    "$ROOT/devices/mediatek_filogic/files/usr/bin/tohsakawrt-clash-direct" \
    "$ROOT/files/usr/bin/tohsakawrt-clash-direct" ; do
    [ -f "$cand" ] && SCRIPT="$cand" && break
done
SCRIPT="${CLASH_DIRECT_OVERRIDE:-${SCRIPT:-}}"
[ -n "${SCRIPT:-}" ] || { echo "FAIL: 找不到 tohsakawrt-clash-direct"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
BIN="$TMP/bin"; mkdir -p "$BIN"
CALLS="$TMP/curl.log"; export CALLS
export TWR_CLASH_MODULE="$TMP/module.yaml"
export TWR_CLASH_RUNTIME="$TMP/runtime.yaml"
export TWR_CLASH_API="http://127.0.0.1:9090"

# 桩件 curl：记录调用并回 204（模拟 Mihomo 热重载成功）
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "$CALLS"
echo 204
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

reset_files() {
    cat > "$TWR_CLASH_MODULE" <<'EOF'
rules:
# === TG_DIRECT_RULES_START ===
  - DOMAIN-SUFFIX,fxxk.dedyn.io,直连
# === TG_DIRECT_RULES_END ===
  - RULE-SET,private_ip,直连,no-resolve
EOF
    cat > "$TWR_CLASH_RUNTIME" <<'EOF'
# 生成的运行配置（注释被剥掉）
rules:
- RULE-SET,geolocation-!cn,🚀 默认代理
- MATCH,🐟 漏网之鱼
EOF
    : > "$CALLS"
}

pass=0; fail=0
check() {
    if [ "$2" -eq 1 ]; then printf 'PASS: %s\n' "$1"; pass=$((pass + 1))
    else printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); fi
}

# ---------- add ----------
reset_files
OUT="$("$SCRIPT" add blog.example.com 2>&1)"
check 'add 返回 ADDED' "$([ "$OUT" = "ADDED" ] && echo 1 || echo 0)"
check '模块文件写进了标记段内' \
    "$(awk '/TG_DIRECT_RULES_START/{f=1} f&&/blog\.example\.com/{found=1} /TG_DIRECT_RULES_END/{f=0} END{print (found?"1":"0")}' "$TWR_CLASH_MODULE" | grep -q 1 && echo 1 || echo 0)"
check '运行配置插在 rules: 之后（优先级最高）' \
    "$([ "$(sed -n '3p' "$TWR_CLASH_RUNTIME")" = "- DOMAIN-SUFFIX,blog.example.com,直连" ] && echo 1 || echo 0)"
check '触发了热重载（PUT /configs 且指向运行配置）' \
    "$(grep -q 'PUT' "$CALLS" && grep -q 'X PUT http://127.0.0.1:9090/configs' "$CALLS" && grep -q '/tmp/.*runtime.yaml' "$CALLS" && echo 1 || echo 0)"

# ---------- 幂等 ----------
: > "$CALLS"
OUT2="$("$SCRIPT" add blog.example.com 2>&1)"
check '重复添加返回 ALREADY' "$([ "$OUT2" = "ALREADY" ] && echo 1 || echo 0)"
CNT="$(grep -c 'DOMAIN-SUFFIX,blog.example.com' "$TWR_CLASH_MODULE")"
check '重复添加不产生重复条目' "$([ "$CNT" -eq 1 ] && echo 1 || echo 0)"

# ---------- 非法域名 ----------
BEFORE="$(md5sum "$TWR_CLASH_MODULE" | awk '{print $1}')"
: > "$CALLS"
if OUT3="$("$SCRIPT" add 'bad;rm -rf /' 2>&1)"; then rc=0; else rc=1; fi
check '非法域名被拒绝' "$([ "$rc" -eq 1 ] && [ "$OUT3" = "ERROR_BAD_DOMAIN" ] && echo 1 || echo 0)"
check '非法域名不改动任何文件' \
    "$([ "$BEFORE" = "$(md5sum "$TWR_CLASH_MODULE" | awk '{print $1}')" ] && [ ! -s "$CALLS" ] && echo 1 || echo 0)"

# ---------- list ----------
OUT4="$("$SCRIPT" list 2>&1)"
check 'list 列出现有直连域名' \
    "$(printf '%s' "$OUT4" | grep -q 'blog.example.com' && printf '%s' "$OUT4" | grep -q 'fxxk.dedyn.io' && echo 1 || echo 0)"

# ---------- del ----------
: > "$CALLS"
OUT5="$("$SCRIPT" del blog.example.com 2>&1)"
check 'del 返回 DELETED' "$([ "$OUT5" = "DELETED" ] && echo 1 || echo 0)"
check 'del 从两个文件里都移除' \
    "$(grep -q 'blog.example.com' "$TWR_CLASH_MODULE" && echo 0 || (grep -q 'blog.example.com' "$TWR_CLASH_RUNTIME" && echo 0 || echo 1))"
check 'del 也触发了热重载' "$(grep -q 'X PUT' "$CALLS" && echo 1 || echo 0)"

# ---------- 重载失败要能报告 ----------
cat > "$BIN/curl" <<'EOF'
#!/bin/sh
echo 502
EOF
chmod +x "$BIN/curl"
if OUT6="$("$SCRIPT" apply 2>&1)"; then rc=0; else rc=1; fi
check '热重载失败时非零退出并报错' \
    "$([ "$rc" -eq 1 ] && printf '%s' "$OUT6" | grep -q 'ERROR_RELOAD' && echo 1 || echo 0)"

check '脚本通过 sh -n' "$(sh -n "$SCRIPT" && echo 1 || echo 0)"

printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
