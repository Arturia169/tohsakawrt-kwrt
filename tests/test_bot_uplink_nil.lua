local lua_root
for _, candidate in ipairs({ "devices/mediatek_filogic/files/usr/lib/lua", "files/usr/lib/lua" }) do
    local probe = io.open(candidate .. "/tohsakawrt/bot.lua", "r")
    if probe then probe:close(); lua_root = candidate; break end
end
assert(lua_root, "cannot locate tohsakawrt Lua payload")
package.path = lua_root .. "/?.lua;" .. lua_root .. "/?/init.lua;" .. package.path
local sent, update_calls, speed_dev = {}, 0, nil
package.preload["tohsakawrt.core"] = function()
    return { get_uci = function(_, _, option, default)
        if option == "enabled" then return "1" end
        if option == "token" then return "dummy-token" end
        if option == "chat_id" then return "77" end
        return default
    end, get_state = function(_, default) return default end, set_state = function() end, log = function() end, exec_line = function() return "" end }
end
package.preload["tohsakawrt.tg"] = function()
    return {
        get_updates = function()
            update_calls = update_calls + 1
            if update_calls == 1 then return { result = {} } end
            if update_calls == 2 then return { result = {
                { update_id = 1, message = { chat = { id = 77, type = "private" }, from = { id = 77 }, text = "/status" } },
                { update_id = 2, message = { chat = { id = 77, type = "private" }, from = { id = 77 }, text = "/uplink" } }
            } } end
            error("__TEST_STOP__")
        end,
        send_msg = function(text) sent[#sent + 1] = text end,
        send_chat_action = function() end
    }
end
package.preload["tohsakawrt.system"] = function()
    return {
        system_metrics = function() return { uptime="up", mem_str="mem", load="load", root_str="disk" } end,
        cpu_temp = function() return "40°C" end,
        public_ip = function() return "1.2.3.4" end,
        uplink_status = function() return { type="unknown", dev=nil } end,
        usb0_ip = function() return "no-ip" end,
        wan_ip = function() return "no-ip" end,
        wan_speed = function(dev) speed_dev = dev; return "0" end
    }
end
package.preload["tohsakawrt.modem"] = function() return { info = function() return { sim_ip="cell-ip", oper="operator", band="band" } end } end
package.preload["tohsakawrt.clash"] = function() return { status = function() return { running=false, version="unknown" } end } end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["nixio"] = function() return {} end
local bot = require("tohsakawrt.bot")
local ok, err = pcall(bot.run)
assert(not ok and tostring(err):find("__TEST_STOP__", 1, true), "run loop should terminate at the test sentinel")
assert(speed_dev == "unknown", "status command must pass a safe interface name to wan_speed")
assert(#sent == 2 and sent[1]:find("unknown (no-ip)", 1, true), "status text must render a fallback interface without throwing")
assert(sent[2]:find("unknown (未知接口)", 1, true), "uplink panel must render nil dev as unknown")
print("PASS: nil uplink.dev is rendered safely in status output")
