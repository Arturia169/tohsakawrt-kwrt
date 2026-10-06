#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FILE=""
for cand in "$ROOT/devices/mediatek_filogic/files/usr/lib/lua/luci/view/modem/modem_info.htm" \
            "$ROOT/files/usr/lib/lua/luci/view/modem/modem_info.htm"; do
    [ -f "$cand" ] && FILE="$cand" && break
done
[ -n "${FILE:-}" ] || { echo "FAIL: 找不到负载"; exit 1; }
grep -Fq 'function html_escape(value)' "$FILE"
grep -Fq 'replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;").replace(/'"'"'/g,"&#39;")' "$FILE"
grep -Fq "sim_info_view+='<tr class=\"tr\"><td class=\"td left\" title=\"'+html_escape(full_name)+'\">'+html_escape(translation[key])+'</td><td class=\"td left\" id=\"'+html_escape(key)+'\">'+html_escape(value)+'</td></tr>';" "$FILE"
grep -Fq "network_info_view+='<tr class=\"tr\"><td class=\"td left\" title=\"'+html_escape(full_name)+'\">'+html_escape(label_name)+'</td><td class=\"td left\" id=\"'+html_escape(key)+'\">'+html_escape(value)+'</td></tr>';" "$FILE"
grep -Fq "cell_info_view+='<tr class=\"tr\"><td class=\"td left\" title=\"'+html_escape(full_name)+'\">'+html_escape(translation[key])+'</td><td class=\"td left\" id=\"'+html_escape(key)+'\">'+(value_is_html?value:html_escape(value))+'</td></tr>';" "$FILE"
echo 'PASS: modem SIM, network, and cell innerHTML values use HTML escaping'
