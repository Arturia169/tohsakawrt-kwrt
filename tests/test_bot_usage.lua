-- 回归用例：分发器必须把命令名写进使用统计（/tmp/tohsakawrt-bot-usage），
-- 这是后续"按真实使用裁剪命令"的唯一数据来源，不能悄悄失效。
package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;" .. package.path

local USAGE = "/tmp/tohsakawrt-bot-usage"

local function reset_usage()
    local f = io.open(USAGE, "w")
    if f then f:close() end
end

local function usage_has(pattern)
    local f = io.open(USAGE, "r")
    if not f then return false end
    local found = false
    for line in f:lines() do
        if line:match(pattern) then found = true break end
    end
    f:close()
    return found
end

local function dispatch(text)
    local updates = 0
    local configured_chat_id = "567890"

    for _, name in ipairs({
        "tohsakawrt.bot", "tohsakawrt.bot_common", "tohsakawrt.bot_net", "tohsakawrt.bot_sys",
        "tohsakawrt.bot_direct", "tohsakawrt.bot_modem", "tohsakawrt.bot_esim",
        "tohsakawrt.core", "tohsakawrt.tg", "tohsakawrt.system", "tohsakawrt.modem",
        "tohsakawrt.clash", "tohsakawrt.esim", "nixio",
    }) do
        package.loaded[name] = nil
    end

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
            log = function() end,
        }
    end
    package.preload["tohsakawrt.tg"] = function()
        return {
            get_updates = function()
                updates = updates + 1
                if updates == 1 then return { result = {} } end
                if updates == 2 then
                    return { result = { { update_id = 2, message = {
                        chat = { id = configured_chat_id, type = "private" },
                        from = { id = configured_chat_id },
                        text = text } } } }
                end
                error("__TEST_STOP__")
            end,
            send_chat_action = function() end,
            send_msg = function() end,
        }
    end
    package.preload["tohsakawrt.system"] = function()
        return {
            system_metrics = function()
                return { uptime = "1 day", mem_str = "1 MB", load = "0", root_str = "1 MB" }
            end,
            cpu_temp = function() return "40C" end,
            public_ip = function() return "192.0.2.1" end,
            uplink_status = function() return { type = "wan", dev = "eth0" } end,
            wan_ip = function() return "192.0.2.2" end,
            usb0_ip = function() return "192.0.2.3" end,
            wan_speed = function() return "0 Mbps" end,
        }
    end
    package.preload["tohsakawrt.modem"] = function()
        return {
            info = function()
                return { oper = "test", mode = "LTE", band = "B3", sim_ip = "192.0.2.4" }
            end,
            get_port = function() return "/dev/ttyUSB-test" end,
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
end

reset_usage()
dispatch("/status")
assert(usage_has(" cmd /status$"), "slash command must be recorded as 'cmd /status'")
assert(usage_has("^%d+ "), "usage record must be prefixed with a timestamp")

reset_usage()
dispatch("看板")
assert(usage_has(" text plain$"), "free text must be recorded as 'text plain' without payload")

print("PASS: command usage tracking records slash commands and free text separately")
