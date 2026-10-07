#!/bin/sh
# 验证 push_bark 会把 Telegram HTML 正文转成 Bark 可显示的纯文本。
# 背景：Bark 只渲染纯文本 / markdown，不渲染 HTML。此前 push_bark 直传 HTML，
# 导致手机 Bark 通知里出现 <b> <code> <i> 标签和 &gt; 之类的实体。
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP/bin"

# 桩 curl：把 title / body 两个参数分别落到文件，绝不真的联网
cat > "$TMP/bin/curl" <<'SH'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        body=*)  printf '%s' "${a#body=}"  > "$CURL_BODY_FILE" ;;
        title=*) printf '%s' "${a#title=}" > "$CURL_TITLE_FILE" ;;
    esac
done
exit 0
SH
chmod +x "$TMP/bin/curl"

COMMON=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/lib/tohsakawrt/common.sh" \
            "$ROOT/files/usr/lib/tohsakawrt/common.sh"; do
    [ -f "$cand" ] && COMMON="$cand" && break
done
[ -n "${COMMON:-}" ] || { echo "FAIL: 找不到 common.sh"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }

BODY_FILE="$TMP/body" TITLE_FILE="$TMP/title"
export CURL_BODY_FILE="$BODY_FILE" CURL_TITLE_FILE="$TITLE_FILE"
: > "$BODY_FILE"; : > "$TITLE_FILE"

# 喂入一条典型的卡片正文：含 <b>/<code>、转义过的 &gt;、以及字面 \n
BARK_KEY="testkey" PATH="$TMP/bin:$PATH" sh -c '
    . "$1"
    push_bark \
        "✅ <b>5G 已恢复</b>" \
        "✅ <b>5G 已恢复</b>\n━━━━━━━━━━━━━━━━━━\n📶 <b>当前制式</b>：<code>TDD NR5G</code>\n⏱️ 已持续 &gt; 1 分钟" \
        "active" "glass"
' sh "$COMMON"

# 1. 正文不得残留任何 HTML 标签
if grep -q '<' "$BODY_FILE"; then
    echo "--- 实际正文 ---"; cat "$BODY_FILE"; echo
    fail "正文仍含 '<'（HTML 标签没被剥掉）"
fi
# 2. 实体必须还原
grep -q '&gt;' "$BODY_FILE" && fail "正文仍含 '&gt;'（实体没还原）"
grep -q '已持续 > 1 分钟' "$BODY_FILE" || fail "'&gt;' 未被还原成 '>'"
# 3. \n 必须变成真换行（正文里不得出现字面反斜杠-n）
grep -q '\\n' "$BODY_FILE" && fail "正文里出现了字面 \\n（换行没被转换）"
NL="$(tr -cd '\n' < "$BODY_FILE" | wc -c)"
[ "$NL" -ge 2 ] || fail "正文换行数不足（实际 $NL），\\n 未转成真换行"
# 4. 正文内容必须保留
grep -q '5G 已恢复' "$BODY_FILE"     || fail "正文丢失了标题文本"
grep -q 'TDD NR5G' "$BODY_FILE"      || fail "正文丢失了字段值"
grep -q '运营商\|当前制式' "$BODY_FILE" || fail "正文丢失了字段名"
# 5. 标题同样要过一遍转换
grep -q '<' "$TITLE_FILE" && fail "标题仍含 '<'"

echo 'PASS: push_bark 把 HTML 正文转成了纯文本（无标签、实体还原、换行为真换行）'
