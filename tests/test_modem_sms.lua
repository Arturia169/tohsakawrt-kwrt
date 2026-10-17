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
            elseif raw == "TBC_SMS" then
                return { msg = {
                    { index = 6, sender = "TBC SMS", timestamp = "10/17/26 19:25:47",
                        content = "Sms Code: 3954" }
                } }
            end
            error("invalid JSON")
        end
    }
end

local modem = require("tohsakawrt.modem")
local function reset_case(recv, overrides)
    current_recv = recv
    states = {
        sms_last_used = "4",
        sms_last_ts = "0",
        sms_last_index = "4",
        sms_last_sig = "old"
    }
    for k, v in pairs(overrides or {}) do states[k] = v end
    state_writes = {}
end

for _, bad_recv in ipairs({ "", "INVALID_JSON" }) do
    reset_case(bad_recv)
    local result = modem.sms_poll_new()
    assert(type(result) == "table" and #result == 0, "failed SMS read must return an empty table")
    assert(#state_writes == 0 and states.sms_last_used == "4" and states.sms_last_ts == "0"
        and states.sms_last_index == "4",
        "failed SMS read must preserve all cursors so the next poll can retry")
end

reset_case("VALID_SMS")
local messages = modem.sms_poll_new()
assert(#messages == 1 and messages[1].code == "123456", "successful SMS read must return the new message")
assert(states.sms_last_used == "5" and states.sms_last_ts == "20260620120000"
    and states.sms_last_index == "5", "successful SMS read must advance used/ts/index")
assert(#state_writes == 4, "successful SMS read must persist used/ts/index/sig")
local valid_sig = states.sms_last_sig

-- 同一批数据再轮询一次，不能重复推送。
reset_case("VALID_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20260620120000",
    sms_last_index = "5",
    sms_last_sig = valid_sig
})
local none = modem.sms_poll_new()
assert(#none == 0, "an unchanged inbox must not be pushed twice")
assert(#state_writes == 0, "a no-op poll must not rewrite cursors")

-- 关键回归：used 计数不变（5→5）、时间戳比上一轮更早（格鲁吉亚 +04 的 19:25
-- 看起来比香港 +08 的 22:32 早），但存储索引从 5 涨到 6 —— 必须仍判定为新短信。
reset_case("TBC_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "5",
    sms_last_sig = "old"
})
local tbc = modem.sms_poll_new()
assert(#tbc == 1 and tbc[1].sender == "TBC SMS",
    "new storage index must be detected even when used count and timestamp look older")
assert(states.sms_last_index == "6", "new storage index must advance the index cursor")
assert(states.sms_last_ts == "20261017223211", "legacy timestamp cursor must not move backwards")

-- 同一条 TBC 短信再轮询一次，不能重复推送。
reset_case("TBC_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "6",
    sms_last_sig = states.sms_last_sig
})
local again = modem.sms_poll_new()
assert(#again == 0, "an already seen SMS must not be pushed twice")
assert(#state_writes == 0, "a no-op poll must not rewrite cursors")

print("PASS: SMS poll detects new storage indexes across timezone/count changes, preserves cursors on failure, and never re-pushes")
