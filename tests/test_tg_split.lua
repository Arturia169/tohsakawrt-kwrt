package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 覆盖两笔欠账：① 超长消息自动分片 ② 被限流(429)退避重试

local payloads, logs = {}, {}
local parse_calls = 0
local parse_mode_429 = false

local function encode(v)
    local t = type(v)
    if t == "string" then
        return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local n = 0
        local is_array = true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" then is_array = false end
        end
        local parts = {}
        if is_array and n > 0 then
            for i = 1, #v do parts[#parts + 1] = encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, val in pairs(v) do
            parts[#parts + 1] = '"' .. tostring(k) .. '":' .. encode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(_, _, option, default)
            if option == "token" then return "test-token" end
            if option == "chat_id" then return "12345" end
            if option == "enabled" then return "1" end
            return default
        end,
        init = function() end,
        log = function(tag, message) logs[#logs + 1] = { tag = tag, message = message } end,
        exec = function(cmd)
            local path = cmd:match("@([^%s']+)")
            if path then
                local f = io.open(path, "r")
                if f then
                    payloads[#payloads + 1] = f:read("*a")
                    f:close()
                end
            end
            return "API_OK"
        end
    }
end
package.preload["luci.jsonc"] = function()
    return {
        stringify = encode,
        parse = function()
            parse_calls = parse_calls + 1
            if parse_mode_429 and parse_calls == 1 then
                return {
                    ok = false,
                    error_code = 429,
                    description = "Too Many Requests: retry after 0",
                    parameters = { retry_after = 0 }
                }
            end
            return { ok = true, result = { message_id = 7 } }
        end
    }
end

os.execute("mkdir -p /tmp/tohsakawrt")
local tg = require("tohsakawrt.tg")

-- ① 超长消息必须被拆成多条，且每条都在上限之内、键盘只挂最后一条
local lines = {}
for i = 1, 300 do
    lines[i] = string.format("第 %03d 行：<b>加粗内容</b> <i>斜体内容</i> <code>代码内容</code> 填充填充填充", i)
end
local long_text = table.concat(lines, "\n")
assert(#long_text > 12000, "测试文本需要足够长，实际 " .. #long_text)

payloads = {}
local kb = { { { text = "按钮", callback_data = "refresh_status" } } }
local res = tg.send_msg(long_text, kb)
assert(type(res) == "table" and res.ok == true, "分片发送的返回值应是最后一次调用的结果")

local n = #payloads
local expect_min = math.ceil(#long_text / 4000)
assert(n >= expect_min, string.format("分片数量偏少：%d 片，按长度至少应 %d 片", n, expect_min))
assert(n <= expect_min + 2, string.format("分片数量偏多：%d 片，按长度约 %d 片", n, expect_min))
for i, body in ipairs(payloads) do
    assert(#body < 4096, string.format("第 %d 片总长度 %d 超过上限", i, #body))
    assert(body:find('"parse_mode":"HTML"', 1, true), string.format("第 %d 片丢失 parse_mode", i))
end
assert(payloads[n]:find("按钮", 1, true), "按钮必须挂在最后一片")
assert(not payloads[1]:find("按钮", 1, true), "按钮不应挂在第一片")
assert(payloads[2]:find("续 2/", 1, true), "第二片应带续页标记")
assert(payloads[1]:find("第 001 行", 1, true), "第一片应包含开头")
assert(payloads[n]:find("第 300 行", 1, true), "最后一片应包含结尾")

-- 标签平衡：不该出现降级为纯文本的情况（这些内容的标签都是自平衡的）
for i, body in ipairs(payloads) do
    assert(body:find('"parse_mode":"HTML"', 1, true), string.format("第 %d 片被误降级为纯文本", i))
end

-- ② 429 必须先退避再重试，而不是直接失败丢消息
payloads, logs = {}, {}
parse_mode_429 = true
parse_calls = 0
local retried = tg.send_msg("限流测试")
assert(parse_calls == 2, "遇到 429 必须重试一次，实际解析次数 " .. parse_calls)
assert(type(retried) == "table" and retried.ok == true, "重试成功后应返回正常结果")
local saw_429 = false
for _, l in ipairs(logs) do
    if l.message and l.message:find("429", 1, true) then saw_429 = true end
end
assert(saw_429, "429 必须留下日志，不能静默")

print("PASS: 超长消息分片发送（键盘挂末片、每片不超限），429 退避重试并留日志")
