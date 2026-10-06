local sent, api_response = {}, nil
package.preload["tohsakawrt.core"] = function()
    return {
        exec = function() return "api-response" end,
        log = function() end
    }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function(message) sent[#sent + 1] = message; return { ok = true } end }
end
package.preload["luci.jsonc"] = function()
    return {
        stringify = function() return "{}" end,
        parse = function() return api_response end
    }
end
local original_open, original_remove = io.open, os.remove
local flowcard_script
for _, candidate in ipairs({
    "devices/mediatek_filogic/files/usr/bin/tohsakawrt-flowcard-daily",
    "files/usr/bin/tohsakawrt-flowcard-daily"
}) do
    local probe = io.open(candidate, "r")
    if probe then probe:close(); flowcard_script = candidate; break end
end
assert(flowcard_script, "cannot locate tohsakawrt-flowcard-daily payload")
io.open = function(path, mode)
    if path == "/tmp/flowcard_req.json" and mode == "w" then
        return { write = function() return true end, close = function() return true end }
    end
    if path == "/etc/tohsakawrt/flowcard_daily.json" and mode == "r" then return nil end
    if path == "/etc/tohsakawrt/flowcard_daily.json" and mode == "w" then
        return { write = function() return true end, close = function() return true end }
    end
    return original_open(path, mode)
end
api_response = { code = "200", data = { card = { total_flow = 102400, used_flow = 51200, left_flow = 51200, package_end_time = 1735689600 } } }
assert(pcall(dofile, flowcard_script), "numeric expiry and string code must be accepted")
assert(#sent == 1 and sent[1]:find("1735689600", 1, true), "successful report must render numeric expiry as text")
assert(sent[1]:find("每日消耗报表", 1, true), "string 200 must select the successful report path")
api_response = { code = "200", data = { card = "bad-card" } }
assert(pcall(dofile, flowcard_script), "invalid card type must not crash the process")
assert(sent[2] == "❌ <b>流量卡每日用量统计失败</b>：接口数据读取或格式化异常", "invalid card must send a failure notification")
io.open, os.remove = original_open, original_remove
print("PASS: flowcard accepts numeric expiry/string code and notifies on malformed card data")
