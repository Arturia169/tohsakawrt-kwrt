package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local response
local logs = {}
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, option, default)
            if option == "token" then return "test-token" end
            if option == "chat_id" then return "12345" end
            if option == "enabled" then return "1" end
            return default
        end,
        init = function() end,
        exec = function() return response end,
        log = function(tag, message) logs[#logs + 1] = { tag = tag, message = message } end
    }
end
package.preload["luci.jsonc"] = function()
    return {
        stringify = function() return "{}" end,
        parse = function(raw)
            if raw == "API_ERROR" then
                return { ok = false, description = "Bad Request: message is too long" }
            end
            if raw == "API_SUCCESS" then return { ok = true, result = { message_id = 19 } } end
            error("unexpected response")
        end
    }
end

os.execute("mkdir -p /tmp/tohsakawrt")
local tg = require("tohsakawrt.tg")
response = "API_ERROR"
local failed = tg.send_msg("test")
assert(failed == nil, "Telegram API failure must return nil")
assert(#logs == 1 and logs[1].tag == "Tg" and logs[1].message == "API error: Bad Request: message is too long",
    "Telegram API failure must log the exact description")

response = "API_SUCCESS"
local succeeded = tg.send_msg("test")
assert(type(succeeded) == "table" and succeeded.ok == true and succeeded.result.message_id == 19,
    "successful Telegram response must retain its parsed table")
assert(#logs == 1, "successful response must not add an error log")

print("PASS: Telegram API errors are logged and returned as nil while success responses are preserved")
