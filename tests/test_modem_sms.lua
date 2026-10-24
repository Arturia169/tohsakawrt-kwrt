package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local current_recv
local states
local state_writes
local current_used = 5
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, _, default) return default end,
        -- 必须和 core.get_state 一样 trim：签名/正文以空格结尾时，写进去的签名
        -- 读回来会被截短，这正是"每 12 秒重复推送同一条短信"的根因。
        get_state = function(key, default)
            local v = states[key]
            if not v or v == "" then return default end
            return v:match("^%s*(.-)%s*$")
        end,
        set_state = function(key, value)
            states[key] = value
            state_writes[#state_writes + 1] = { key = key, value = value }
        end,
        log = function() end,
        exec = function(command)
            if command:find(" status ", 1, true) then
                return string.format("total: %d, unread: 1, used: %d\n", current_used, current_used)
            end
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
            elseif raw == "DUP_SMS" then
                return { msg = {
                    { index = 6, sender = "+8613800000000", timestamp = "06/20/26 12:00:00",
                        content = "验证码 123456" }
                } }
            elseif raw == "TBC_SMS" then
                return { msg = {
                    { index = 6, sender = "TBC SMS", timestamp = "10/17/26 19:25:47",
                        content = "Sms Code: 3954" }
                } }
            elseif raw == "SPACE_SMS" then
                return { msg = {
                    { index = 7, sender = "SPACE", timestamp = "10/17/26 20:00:00",
                        content = "hello  " }
                } }
            elseif raw == "EMPTY_SMS" then
                return { msg = {
                    { index = 8, sender = "", timestamp = "", content = "" }
                } }
            elseif raw == "MULTI_PART1" then
                return { msg = {
                    { index = 9, sender = "Multi", timestamp = "10/23/26 03:00:00",
                        reference = 1, part = 1, total = 2, content = "A" }
                } }
            elseif raw == "MULTI_BOTH" then
                return { msg = {
                    { index = 9, sender = "Multi", timestamp = "10/23/26 03:00:00",
                        reference = 1, part = 1, total = 2, content = "A" },
                    { index = 10, sender = "Multi", timestamp = "10/23/26 03:00:00",
                        reference = 1, part = 2, total = 2, content = "B" }
                } }
            elseif raw == "RENUMBER_SMS" then
                return { msg = {
                    { index = 35, sender = "Old", timestamp = "10/21/26 01:24:55",
                        content = "old message" }
                } }
            elseif raw == "MASS_SMS" then
                local msgs = {}
                for i = 35, 44 do
                    msgs[#msgs + 1] = { index = i, sender = "Bulk",
                        timestamp = "10/24/26 07:00:00", content = "bulk " .. i }
                end
                return { msg = msgs }
            end
            error("invalid JSON")
        end
    }
end

local modem = require("tohsakawrt.modem")
local function reset_case(recv, overrides, used)
    current_recv = recv
    current_used = used or 5
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

-- 重复存储/网络重发：内容、发件人、时间与上一条完全相同，只是索引变成 6。
-- 只推进游标，不能再次推送（实机 #SIMWorld 同一条旧短信被重存成新 index）。
reset_case("DUP_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20260620120000",
    sms_last_index = "5",
    sms_last_sig = valid_sig
}, 6)
local dup = modem.sms_poll_new()
assert(#dup == 0, "a duplicate copy with a new index must not be pushed")
assert(states.sms_last_index == "6", "a duplicate copy must still advance the index cursor")

-- 关键回归：used 计数不变（5→5）、时间戳比上一轮更早（格鲁吉亚 +04 的 19:25
-- 看起来比香港 +08 的 22:32 早），但存储索引从 5 涨到 6 —— 必须仍判定为新短信。
reset_case("TBC_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "5",
    sms_last_sig = "old"
}, 6)
local tbc = modem.sms_poll_new()
assert(#tbc == 1 and tbc[1].sender == "TBC SMS",
    "new storage index must be detected even when used count and timestamp look older")
assert(states.sms_last_index == "6", "new storage index must advance the index cursor")
assert(states.sms_last_ts == "20261017223211", "legacy timestamp cursor must not move backwards")

-- 同一条 TBC 短信再轮询一次，不能重复推送。
reset_case("TBC_SMS", {
    sms_last_used = "6",
    sms_last_ts = "20261017223211",
    sms_last_index = "6",
    sms_last_sig = states.sms_last_sig
}, 6)
local again = modem.sms_poll_new()
assert(#again == 0, "an already seen SMS must not be pushed twice")
assert(#state_writes == 0, "a no-op poll must not rewrite cursors")

-- 关键回归：短信正文以空格结尾（#SIMWorld 实测结尾两个空格）。core.get_state 会 trim
-- 首尾空白，如果签名直接包含正文，写进去的签名会被截短，读回来永远不等于新签名，
-- 兜底分支就会每 12 秒把同一条短信重推一次。签名改成"长度+哈希"后必须只推一次。
reset_case("SPACE_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "6",
    sms_last_sig = "old"
}, 6)
local spaced = modem.sms_poll_new()
assert(#spaced == 1, "a trailing-space SMS must be delivered once")
reset_case("SPACE_SMS", {
    sms_last_used = "6",
    sms_last_ts = "20261017223211",
    sms_last_index = "7",
    sms_last_sig = states.sms_last_sig
}, 6)
local repeated = modem.sms_poll_new()
assert(#repeated == 0, "a trailing-space SMS must not be pushed again every poll")

-- 空短信（状态报告/静默短信/空 PDU）：不推送，但索引必须推进，否则每轮都会重查。
reset_case("EMPTY_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "7",
    sms_last_sig = "old"
}, 6)
local empty = modem.sms_poll_new()
assert(#empty == 0, "an empty SMS must not be pushed")
assert(states.sms_last_index == "8", "an empty SMS must still advance the index cursor")

-- 多段短信只到第一段：不推半截，但原始索引要推进到 9。
reset_case("MULTI_PART1", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "8",
    sms_last_sig = "old"
}, 6)
local part1 = modem.sms_poll_new()
assert(#part1 == 0, "an incomplete multipart SMS must not be pushed")
assert(states.sms_last_index == "9", "an incomplete multipart SMS must advance the raw index")

-- 第二段到齐：只推一次完整内容，索引用最后一段的 10。
reset_case("MULTI_BOTH", {
    sms_last_used = "5",
    sms_last_ts = "20261017223211",
    sms_last_index = "9",
    sms_last_sig = "old"
}, 6)
local full = modem.sms_poll_new()
assert(#full == 1 and full[1].content == "AB",
    "a complete multipart SMS must be pushed once with the full content")
assert(full[1].index == 10, "a complete multipart SMS must use the last part index")
assert(states.sms_last_index == "10", "a complete multipart SMS must advance to the last part index")

-- 索引整体重编号但存储条数没变：只推进游标，不能把历史短信全量重推。
reset_case("RENUMBER_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261021012455",
    sms_last_index = "34",
    sms_last_sig = "old"
}, 5)
local renum = modem.sms_poll_new()
assert(#renum == 0, "index renumbering without storage growth must not push old SMS")
assert(states.sms_last_index == "35", "index renumbering must still advance the cursor")

-- 存储只多 1 条却冒出 10 条新索引：只推最新 1 条，避免刷屏。
reset_case("MASS_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261021012455",
    sms_last_index = "34",
    sms_last_sig = "old"
}, 6)
local mass = modem.sms_poll_new()
assert(#mass == 1 and mass[1].index == 44,
    "a mass index jump must only push the newest message")
assert(states.sms_last_index == "44", "a mass index jump must advance to the max index")

-- 游标异常接近 0 但收件箱有大量历史短信：不能全量重推。
reset_case("MASS_SMS", {
    sms_last_used = "5",
    sms_last_ts = "20261021012455",
    sms_last_index = "0",
    sms_last_sig = "old"
}, 6)
local reset = modem.sms_poll_new()
assert(#reset == 0, "a near-zero cursor with a full inbox must not replay history")
assert(states.sms_last_index == "44", "a near-zero cursor must be rebuilt to the max index")

print("PASS: SMS poll detects new storage indexes across timezone/count changes, preserves cursors on failure, skips empty/incomplete SMS, caps mass renumbering, and never re-pushes")
