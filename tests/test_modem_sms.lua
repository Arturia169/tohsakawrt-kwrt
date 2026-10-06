package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local current_recv
local states
local state_writes
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, _, default) return default end,
        get_state = function(key, default) return states[key] or default end,
        set_state = function(key, value)
            states[key] = value
            state_writes[#state_writes + 1] = { key = key, value = value }
        end,
        exec = function(command)
            if command:find(" status ", 1, true) then return "total: 5, unread: 1, used: 5\n" end
            if command:find(" recv ", 1, true) then return current_recv end
            error("unexpected modem command: " .. command)
        end
    }
end
package.preload["nixio"] = function() return { fs = { stat = function() return true end } } end
package.preload["luci.jsonc"] = function()
    return {
        parse = function(raw)
            if raw == "VALID_SMS" then
                return { msg = {
                    { index = 5, sender = "+8613800000000", timestamp = "06/20/26 12:00:00",
                        content = "验证码 123456" }
                } }
            end
            error("invalid JSON")
        end
    }
end

local modem = require("tohsakawrt.modem")
local function reset_case(recv)
    current_recv = recv
    states = { sms_last_used = "4", sms_last_ts = "0" }
    state_writes = {}
end

for _, bad_recv in ipairs({ "", "INVALID_JSON" }) do
    reset_case(bad_recv)
    local result = modem.sms_poll_new()
    assert(type(result) == "table" and #result == 0, "failed SMS read must return an empty table")
    assert(#state_writes == 0 and states.sms_last_used == "4" and states.sms_last_ts == "0",
        "failed SMS read must preserve both cursors so the next poll can retry")
end

reset_case("VALID_SMS")
local messages = modem.sms_poll_new()
assert(#messages == 1 and messages[1].code == "123456", "successful SMS read must return the new message")
assert(states.sms_last_used == "5" and states.sms_last_ts == "20260620120000",
    "successful SMS read must advance both cursors")
assert(#state_writes == 2, "successful SMS read must persist both cursors")

print("PASS: SMS read failures preserve cursors and successful reads advance them")
