package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 📊 查流量（机器人侧）：
--   ① 必须带 FLOWCARD_PRINT_ONLY=1 调用脚本（否则会写台账、把当晚日报的差值算错）
--   ② 脚本输出原样转发给用户
--   ③ 输出为空时给出明确失败提示（不能空白一张卡片）

local sent, commands = {}, {}

package.preload["tohsakawrt.core"] = function()
    return {
        init = function() end,
        log = function() end,
        exec = function(cmd) commands[#commands + 1] = cmd; return _G.__FAKE_FLOW_OUT or "" end,
        exec_line = function() return "" end,
        get_uci = function(_, _, option, default) return default end,
        get_state = function(_, default) return default end,
        set_state = function() end,
        progress_bar = function() return "" end,
    }
end
package.preload["tohsakawrt.tg"] = function()
    return {
        send_msg = function(text) sent[#sent + 1] = text; return { ok = true } end,
        edit_msg = function(_, text) sent[#sent + 1] = text; return { ok = true } end,
        answer_callback = function() end,
        answer_and_edit = function(_, _, _, text) sent[#sent + 1] = text; return { ok = true } end,
        send_chat_action = function() end,
    }
end
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function() return {} end

local bot_sys = require("tohsakawrt.bot_sys")

-- ① 正常情况：脚本返回报表 → 原样转发
_G.__FAKE_FLOW_OUT = "📊 <b>流量卡</b>\n剩余 74.2 GB"
sent, commands = {}, {}
bot_sys.cmd_flowcard()
assert(#sent == 1, "应发送一条消息，实际 " .. #sent)
assert(sent[1]:find("剩余 74.2 GB", 1, true), "应原样转发脚本输出")
assert(#commands == 1, "应只调用一次脚本，实际 " .. #commands)
assert(commands[1]:find("FLOWCARD_PRINT_ONLY=1", 1, true),
    "必须带 FLOWCARD_PRINT_ONLY=1（否则会写台账）: " .. tostring(commands[1]))
assert(commands[1]:find("/usr/bin/tohsakawrt-flowcard-daily", 1, true),
    "应调用流量卡脚本: " .. tostring(commands[1]))

-- ② 查询失败（空输出）→ 必须给出明确提示，不能空白
_G.__FAKE_FLOW_OUT = ""
sent, commands = {}, {}
bot_sys.cmd_flowcard()
assert(#sent == 1 and sent[1]:find("查询失败", 1, true), "空输出时应提示查询失败")

print("PASS: 查流量按钮带 PRINT_ONLY 调用脚本、原样转发、失败有提示")
