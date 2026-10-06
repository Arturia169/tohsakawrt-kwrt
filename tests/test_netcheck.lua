package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local sent_text
package.preload["tohsakawrt.core"] = function() return {} end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function(text) sent_text = text end }
end
package.preload["tohsakawrt.system"] = function()
    return {
        wan_gateway = function() return "192.168.1.1" end,
        ping_metric = function(target)
            if target == "192.168.1.1" then return true, "🟠", "207.8", "0% 丢包" end
            if target == "223.5.5.5" then return true, "🟢", "12.3", "0% 丢包" end
            return true, "🟡", "81.4", "0% 丢包"
        end,
        http_metric = function(url)
            if url:find("hicloud", 1, true) then return true, "🟢", "421" end
            return true, "🟠", "1200"
        end
    }
end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function()
    return { proxy_delay = function() return 211 end }
end
package.preload["tohsakawrt.esim"] = function() return {} end

local bot = require("tohsakawrt.bot")
bot.cmd_ping()

assert(type(sent_text) == "string", "cmd_ping must send the rendered health card")
assert(sent_text:find("<code>", 1, true) and sent_text:find("</code>", 1, true),
    "rendered health card must contain real code tags")
assert(not sent_text:find("&lt;code&gt;", 1, true), "rendered health card escaped its code opening tag")
assert(not sent_text:find("&lt;/code&gt;", 1, true), "rendered health card escaped its code closing tag")
assert(not sent_text:find("&lt;b&gt;", 1, true), "rendered health card escaped its bold opening tag")
assert(sent_text:find("🟠 <code>207.8 ms</code>", 1, true), "ICMP metric must retain its actual severity icon and value")
assert(sent_text:find("评级：🟢 良好  🟡 一般  🟠 偏高  🔴 不可达", 1, true),
    "rating legend must include all metric status icons")
assert(sent_text:find("阈值：ICMP 80 / 150 ms · HTTP 500 / 1000 ms", 1, true),
    "rating legend must show the separate ICMP and HTTP thresholds")

print("PASS: netcheck card keeps Telegram HTML tags and matches metric icons and thresholds")
