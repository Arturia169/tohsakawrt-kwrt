package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local exec_calls = 0
local exec_commands = {}
local states = {}
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, _, default) return default end,
        get_state = function(key, default) return states[key] or default end,
        set_state = function(key, value) states[key] = value end,
        shell_quote = function(s) return "'" .. tostring(s) .. "'" end,
        exec = function(command)
            exec_calls = exec_calls + 1
            exec_commands[#exec_commands + 1] = command
            return ""
        end
    }
end
package.preload["nixio"] = function()
    return { fs = { stat = function() return nil end } }
end
package.preload["luci.jsonc"] = function()
    return { parse = function() error("parse must not run without a modem node") end }
end

local modem = require("tohsakawrt.modem")

assert(modem.port_present() == false, "port_present must report a missing AT node")

local polled = modem.sms_poll_new()
assert(type(polled) == "table" and #polled == 0, "missing modem must yield an empty poll result")
assert(modem.sms_list("ME", 3) == nil, "missing modem must not return a message list")

assert(exec_calls == 0,
    "missing modem must not spawn sms_tool: " .. table.concat(exec_commands, "; "))
assert(next(states) == nil, "missing modem must not touch the SMS cursors")

print("PASS: missing AT node skips sms_tool and leaves SMS cursors untouched")
