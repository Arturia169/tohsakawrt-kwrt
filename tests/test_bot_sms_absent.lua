package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local sent_text = nil
local sms_reads = 0

package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, _, default) return default end,
        get_state = function(_, default) return default end,
        set_state = function() end,
        log = function() end,
        shell_quote = function(s) return "'" .. tostring(s) .. "'" end,
        exec = function(command) error("must not run modem command without a device node: " .. command) end
    }
end
package.preload["tohsakawrt.tg"] = function()
    return {
        send_msg = function(text) sent_text = text end,
        edit_msg = function(_, text) sent_text = text end,
        answer_and_edit = function(_, _, _, text) sent_text = text end,
        answer_callback = function() end,
        send_chat_action = function() end
    }
end
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end
package.preload["tohsakawrt.modem"] = function()
    return {
        get_port = function() return "/dev/ttyUSB3" end,
        port_present = function() return false end,
        sms_list = function()
            sms_reads = sms_reads + 1
            error("must not read SMS without a modem node")
        end
    }
end
package.preload["nixio"] = function()
    return { fs = { stat = function() return nil end } }
end
package.preload["luci.jsonc"] = function()
    return { parse = function() error("parse must not run without a modem node") end }
end

local bot_modem = require("tohsakawrt.bot_modem")
bot_modem.cmd_sms(3)

assert(type(sent_text) == "string", "/sms must reply even when the modem is absent")
assert(sent_text:find("未检测到模组", 1, true), "absent modem must be reported as missing")
assert(not sent_text:find("收件箱为空", 1, true), "absent modem must not be reported as an empty inbox")
assert(sms_reads == 0, "absent modem must not trigger an SMS read")

print("PASS: /sms reports a missing modem instead of an empty inbox")
