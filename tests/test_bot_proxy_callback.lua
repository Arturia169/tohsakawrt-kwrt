package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path
-- 回归用例：走【真实回调分发】点 proxy_menu，必须真的发出代理面板
-- （上一版只直接调函数，没测派发路径，于是 netm 写错这个低级错误溜到了线上）
local sent = {}
package.preload["tohsakawrt.core"] = function()
    return { init=function() end, log=function() end, exec=function() return "" end,
        exec_line=function() return "DIRECT_RULES:1" end,
        get_uci=function(_, _, opt, def)
            if opt == "enabled" or opt == "reminder_enabled" then return "1" end
            if opt == "token" then return "dummy" end
            if opt == "chat_id" or opt == "user_id" then return "77" end
            return def
        end,
        get_state=function(_, d) return d end, set_state=function() end,
        progress_bar=function() return "" end }
end
package.preload["tohsakawrt.tg"] = function()
    local n = 0
    return {
        get_updates = function()
            n = n + 1
            if n == 1 then return { result = {} } end
            if n == 2 then return { result = { { update_id = 1, callback_query = {
                id = "cb1", data = "proxy_menu",
                message = { message_id = 5, chat = { id = 77, type = "private" } },
                from = { id = 77 } } } } } end
            error("__STOP__")
        end,
        send_msg = function(t) sent[#sent + 1] = t; return { ok = true } end,
        edit_msg = function(_, t) sent[#sent + 1] = t; return { ok = true } end,
        answer_callback = function() end,
        answer_and_edit = function(_, _, _, t) sent[#sent + 1] = t; return { ok = true } end,
        send_chat_action = function() end,
    }
end
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function()
    return { status = function() return { running = true, version = "test" } end }
end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function() return {} end

local ok, err = pcall(require("tohsakawrt.bot").run)
assert(tostring(err):find("__STOP__", 1, true), "run 应终止在哨兵处，实际: " .. tostring(err))
assert(#sent >= 1, "点了 proxy_menu 却一条消息都没发（分发路径没走通）")
local found = false
for _, t in ipairs(sent) do if tostring(t):find("代理与分流面板", 1, true) then found = true end end
assert(found, "应发出代理与分流面板，实际发出: " .. tostring(sent[1]):sub(1, 60))
print("PASS: proxy_menu 经过真实回调分发后确实发出了代理面板")
