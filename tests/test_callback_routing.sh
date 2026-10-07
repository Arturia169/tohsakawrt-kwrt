#!/bin/sh
# 静态关卡：payload 里每个字面量 callback_data 都必须有分发分支。
# 今天已因"按钮回调写错"坏过（自编的 clash_status / nodes_menu / clash_restart 全都不存在），
# 所以把它做成用例。注意分发器有三种写法，都要认：
#   data_str == "x"        （精确）
#   data_str:match("^x")   （前缀）
#   data_str:find("^x")    （前缀，另一种写法 —— 漏了它会误报）
set -u
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LUA=""
for c in "$ROOT/devices/mediatek_filogic/files/usr/lib/lua/tohsakawrt" "$ROOT/files/usr/lib/lua/tohsakawrt"; do
    [ -d "$c" ] && LUA="$c" && break
done
[ -n "$LUA" ] || { echo "FAIL: 找不到 lua 负载"; exit 1; }
BOT="$LUA/bot.lua"
[ -f "$BOT" ] || { echo "FAIL: 找不到 bot.lua"; exit 1; }

CB="$(grep -ho 'callback_data = "[^"]*"' "$LUA"/bot*.lua 2>/dev/null | sed 's/.*= "//; s/"$//' | sort -u)"
EXACT="$(grep -o 'data_str == "[^"]*"' "$BOT" | sed 's/.*== "//; s/"$//' | sort -u)"
PREFIX="$( { grep -o 'data_str:match("\^[^"]*"' "$BOT"; grep -o 'data_str:find("\^[^"]*"' "$BOT"; } | sed 's/.*"\^//; s/"$//' | sort -u)"

pass=0
fail=0
for cb in $CB; do
    ok=0
    for e in $EXACT; do [ "$cb" = "$e" ] && ok=1; done
    for p in $PREFIX; do case "$cb" in "$p"*) ok=1 ;; esac; done
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: 按钮回调没有分发分支 → $cb"
    fi
done
echo "  已校验回调 $pass 个，缺失 $fail 个"
printf 'PASS=%s FAIL=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
