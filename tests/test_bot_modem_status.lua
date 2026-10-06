package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local calls
local sent_text
local configured_chat_id = "456789"
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, option, default)
            if option == "enabled" then return "1" end
            if option == "token" then return "test-token" end
            if option == "chat_id" then return configured_chat_id end
            return default
        end,
        get_state = function(_, default) return default end,
        set_state = function() end,
        log = function() end
    }
end
package.preload["tohsakawrt.tg"] = function()
    return {
        get_updates = function()
            calls = calls + 1
            if calls == 1 then return { result = {} } end
            if calls == 2 then
                return { result = { { update_id = 1, message = { chat = { id = configured_chat_id }, text = "/modem" } } } }
            end
            error("__TEST_STOP__")
        end,
        send_chat_action = function() end,
        send_msg = function(text) sent_text = text end
    }
end
package.preload["tohsakawrt.system"] = function() return { usb0_ip = function() return "192.0.2.2" end } end
package.preload["tohsakawrt.modem"] = function()
    return {
        info = function()
            return { oper = "测试运营商", mode = "LTE", band = "B3", sim_ip = "192.0.2.1" }
        end,
        get_port = function() return "/dev/ttyUSB-test" end
    }
end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function()
    return { fs = { stat = function(path) return path == "/dev/ttyUSB-test" and { type = "file" } or nil end } }
end

calls = 0
local bot = require("tohsakawrt.bot")
local ok, err = pcall(bot.run)
assert(not ok and tostring(err):find("__TEST_STOP__", 1, true), "bot loop must exit through the test sentinel")
assert(type(sent_text) == "string", "authorized /modem command must send a status card")
assert(sent_text:find("✅ 已连接", 1, true), "status card must show the stat-confirmed modem as connected")
assert(not sent_text:find("ℹ️ 未检测到", 1, true), "status card must not show a present modem as missing")

print("PASS: /modem status uses nixio stat and reports a present modem as connected")
