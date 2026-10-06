package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local configured_chat_id = "567890"

local function route_message(text)
    local updates = 0
    local modem_calls = 0
    local status_calls = 0

    package.loaded["tohsakawrt.bot"] = nil
    package.loaded["tohsakawrt.bot_common"] = nil
    package.loaded["tohsakawrt.core"] = nil
    package.loaded["tohsakawrt.tg"] = nil
    package.loaded["tohsakawrt.system"] = nil
    package.loaded["tohsakawrt.modem"] = nil
    package.loaded["tohsakawrt.clash"] = nil
    package.loaded["tohsakawrt.esim"] = nil
    package.loaded["nixio"] = nil

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
                updates = updates + 1
                if updates == 1 then return { result = {} } end
                if updates == 2 then
                    return { result = { { update_id = 2, message = { chat = { id = configured_chat_id, type = "private" }, from = { id = configured_chat_id }, text = text } } } }
                end
                error("__TEST_STOP__")
            end,
            send_chat_action = function() end,
            send_msg = function() end
        }
    end
    package.preload["tohsakawrt.system"] = function()
        return {
            system_metrics = function()
                status_calls = status_calls + 1
                return { uptime = "1 day", mem_str = "1 MB", load = "0", root_str = "1 MB" }
            end,
            cpu_temp = function() return "40°C" end,
            public_ip = function() return "192.0.2.1" end,
            uplink_status = function() return { type = "wan", dev = "eth0" } end,
            wan_ip = function() return "192.0.2.2" end,
            usb0_ip = function() return "192.0.2.3" end,
            wan_speed = function() return "0 Mbps" end
        }
    end
    package.preload["tohsakawrt.modem"] = function()
        return {
            info = function()
                modem_calls = modem_calls + 1
                return { oper = "测试运营商", mode = "LTE", band = "B3", sim_ip = "192.0.2.4" }
            end,
            get_port = function() return "/dev/ttyUSB-test" end
        }
    end
    package.preload["tohsakawrt.clash"] = function()
        return { status = function() return { running = true, version = "test" } end }
    end
    package.preload["tohsakawrt.esim"] = function() return {} end
    package.preload["nixio"] = function() return { fs = { stat = function() return true end } } end

    local bot = require("tohsakawrt.bot")
    local ok, err = pcall(bot.run)
    assert(not ok and tostring(err):find("__TEST_STOP__", 1, true), "bot loop must stop at the sentinel")
    return modem_calls, status_calls
end

local modem_calls, status_calls = route_message("模组状态")
assert(modem_calls == 1 and status_calls == 0, "模组状态 must route to the modem panel")
modem_calls, status_calls = route_message("状态")
assert(status_calls == 1 and modem_calls == 0, "状态 must route to the system status panel")

print("PASS: command routing sends 模组状态 to modem and 状态 to system status")
