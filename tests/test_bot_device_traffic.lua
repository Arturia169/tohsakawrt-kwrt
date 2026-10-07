package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
-- 📱 各设备流量：脚本输出要转发，且 MAC 要换成人可读的备注名
local sent, cmds = {}, {}
local FAKE = "1. <code>aa:bb:cc:dd:ee:ff</code>\n   ↓1.00 GB ↑2.00 MB\n"
package.preload["tohsakawrt.core"] = function()
    return { init = function() end, log = function() end,
        exec = function(c) cmds[#cmds + 1] = c; return FAKE end,
        exec_line = function() return "" end,
        get_uci = function(_, _, _, d) return d end,
        get_state = function(_, d) return d end, set_state = function() end,
        progress_bar = function() return "" end }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function(t) sent[#sent + 1] = t; return { ok = true } end,
        edit_msg = function(_, t) sent[#sent + 1] = t; return { ok = true } end,
        answer_callback = function() end,
        answer_and_edit = function(_, _, _, t) sent[#sent + 1] = t; return { ok = true } end,
        send_chat_action = function() end }
end
package.preload["tohsakawrt.system"] = function()
    return { load_aliases = function() return { ["aa:bb:cc:dd:ee:ff"] = "小明的手机" } end }
end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function() return {} end

local m = require("tohsakawrt.bot_sys")
m.cmd_device_traffic()
assert(#sent == 1, "应发送一条消息")
assert(cmds[1] and cmds[1]:find("tohsakawrt-device-traffic", 1, true), "应调用排行脚本")
assert(sent[1]:find("1.00 GB", 1, true), "应保留流量数字")
assert(sent[1]:find("小明的手机", 1, true), "应把 MAC 换成备注名")

-- 脚本不可用时要有明确提示，不能空白
FAKE = "TRAFFIC_UNAVAILABLE"
sent = {}
m.cmd_device_traffic()
assert(#sent == 1 and sent[1]:find("读不到", 1, true), "无数据时应提示")

print("PASS: 各设备流量排行转发、MAC→备注名替换、无数据有提示")
