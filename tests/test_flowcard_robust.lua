package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 覆盖：① 报表健壮性（原有用例）② 缺卡号静默跳过 ③ 到期/额度/用量预警 ④ 紧急提醒只补发一次
-- 全程桩件，不发真实消息

local sent, api_response = {}, nil
local configured_card_no = "12345678"   -- 测试专用假卡号，绝不写真实卡号
local state_read = nil                  -- 读台账时返回的内容（nil = 无台账）
local state_writes = {}                 -- 写台账时捕获的内容
local exec_calls = 0

package.preload["tohsakawrt.core"] = function()
    return {
        exec = function() exec_calls = exec_calls + 1; return "api-response" end,
        log = function() end,
        get_uci = function(_, _, option, default)
            if option == "flowcard_no" then return configured_card_no end
            return default
        end
    }
end
package.preload["tohsakawrt.tg"] = function()
    return { send_msg = function(message) sent[#sent + 1] = message; return { ok = true } end }
end
package.preload["luci.jsonc"] = function()
    return {
        -- 极简编码：只够本用例检查 last_delta_mb / urgent_state
        stringify = function(t)
            local parts = {}
            for k, v in pairs(t) do
                if type(v) == "number" then
                    parts[#parts + 1] = string.format('"%s":%s', tostring(k), tostring(v))
                else
                    parts[#parts + 1] = string.format('"%s":"%s"', tostring(k), tostring(v))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end,
        parse = function(raw)
            if raw == "STATE" then return state_read end
            return api_response
        end
    }
end

local original_open, original_remove = io.open, os.remove
local function writer(sink)
    return {
        write = function(_, s) sink[#sink + 1] = s; return true end,
        close = function() return true end
    }
end
io.open = function(path, mode)
    if path == "/tmp/flowcard_req.json" and mode == "w" then return writer({}) end
    if path == "/etc/tohsakawrt/flowcard_daily.json" and mode == "r" then
        if not state_read then return nil end
        return { read = function() return "STATE" end, close = function() return true end }
    end
    if path == "/etc/tohsakawrt/flowcard_daily.json" and mode == "w" then return writer(state_writes) end
    return original_open(path, mode)
end

-- 允许用环境变量指定脚本路径：实机上用例跑在 /tmp，仓库相对路径不存在
local flowcard_script = os.getenv("FLOWCARD_SCRIPT_OVERRIDE")
if not flowcard_script then
    for _, candidate in ipairs({
        "devices/mediatek_filogic/files/usr/bin/tohsakawrt-flowcard-daily",
        "files/usr/bin/tohsakawrt-flowcard-daily"
    }) do
        local probe = io.open(candidate, "r")
        if probe then probe:close(); flowcard_script = candidate; break end
    end
end
assert(flowcard_script, "cannot locate tohsakawrt-flowcard-daily payload")

local function make_card(overrides)
    local c = {
        total_flow = 102400,
        used_flow = 51200,
        left_flow = 51200,
        package_end_time = "2030-01-01T00:00:00",
        operator_name = "测试运营商",
        package_name = "测试套餐"
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function run_case(card_overrides, prev_state)
    sent, state_writes, exec_calls = {}, {}, 0
    state_read = prev_state
    api_response = { code = "200", data = { card = make_card(card_overrides) } }
    assert(pcall(dofile, flowcard_script), "用例不应崩溃")
    return state_writes[1] or ""
end

local function any_message(pattern)
    for _, m in ipairs(sent) do
        if tostring(m):find(pattern, 1, true) then return true end
    end
    return false
end

-- ① 原有用例：数字时间戳 + 字符串 code 必须被接受
-- 注意：这里必须用"未来"的时间戳（1893456000 = 2030-01-01），否则会被新的到期预警
-- 判为紧急并额外补发提醒，消息数不再是 1（那属于用例 ⑧ 的场景）
run_case({ package_end_time = 1893456000 }, nil)
assert(#sent == 1 and tostring(sent[1]):find("1893456000", 1, true), "数字到期时间必须渲染为文本")
assert(tostring(sent[1]):find("每日消耗报表", 1, true), "字符串 200 必须走成功报表路径")
assert(not any_message("需要注意"), "额度充足且未到期时不应出现预警")

-- ② 原有用例：畸形卡数据必须发失败通知而不崩溃
sent, state_writes, exec_calls = {}, {}, 0
state_read = nil
api_response = { code = "200", data = { card = "bad-card" } }
assert(pcall(dofile, flowcard_script), "畸形卡数据不应崩溃")
assert(#sent == 1 and sent[1] == "❌ <b>流量卡每日用量统计失败</b>：接口数据读取或格式化异常", "畸形卡数据必须发失败通知")

-- ③ 原有用例：未配置卡号必须静默跳过
sent, state_writes, exec_calls = {}, {}, 0
configured_card_no = ""
assert(pcall(dofile, flowcard_script), "缺卡号不应崩溃")
assert(#sent == 0, "缺卡号不得发送任何消息")
assert(exec_calls == 0, "缺卡号不得请求卡商接口")
assert(#state_writes == 0, "缺卡号不得写台账")
configured_card_no = "12345678"

-- ④ 剩余不足 10%：报表带预警，且因首次紧急而额外补发一条
run_case({ left_flow = 5120 }, nil)   -- 5%
assert(any_message("剩余流量不足"), "剩余不足时必须给出预警")
assert(#sent == 2, "首次进入紧急状态应额外补发一条提醒，实际消息数 " .. #sent)
assert(any_message("流量卡预警"), "补发的提醒应有独立标题")
assert(state_writes[1] and state_writes[1]:find('"urgent_state":"1"', 1, true), "台账必须记住紧急状态")

-- ⑤ 已处于紧急状态：报表仍预警，但不再重复补发
run_case({ left_flow = 5120 }, { last_used_mb = 51000, last_delta_mb = 100, urgent_state = "1" })
assert(any_message("剩余流量不足"), "紧急状态未解除时报表仍应预警")
assert(#sent == 1, "已紧急时不得重复补发提醒，实际消息数 " .. #sent)

-- ⑥ 额度偏低但未紧急（预警阈值 20%）：只提示、不补发
run_case({ left_flow = 15360 }, nil)   -- 15%
assert(any_message("剩余流量偏低"), "低于预警阈值必须提示")
assert(#sent == 1, "未达紧急线时不应补发提醒")

-- ⑦ 套餐 3 天后到期：提示但不紧急
local soon = os.date("%Y-%m-%dT%H:%M:%S", os.time() + 3 * 86400)
run_case({ package_end_time = soon }, nil)
assert(any_message("天后到期"), "临近到期必须提示")
assert(#sent == 1, "仅临期未到期时不应补发紧急提醒")

-- ⑧ 套餐已到期：紧急提示
local past = os.date("%Y-%m-%dT%H:%M:%S", os.time() - 86400)
run_case({ package_end_time = past }, nil)
assert(any_message("套餐已到期"), "已到期必须明确提示")
assert(#sent == 2, "已到期属紧急，应额外补发提醒")

-- ⑨ 今日用量突增：提示并记录，供明日比较
run_case({ used_flow = 55000, left_flow = 47400 }, { last_used_mb = 50000, last_delta_mb = 100, urgent_state = "0" })
assert(any_message("今日用量偏高"), "用量突增必须提示")
assert(state_writes[1] and state_writes[1]:find('"last_delta_mb":5000', 1, true), "台账必须记录今日用量供明日比较")

io.open, os.remove = original_open, original_remove
print("PASS: 流量卡日报健壮性 + 缺卡号跳过 + 到期/额度/用量突增预警（紧急提醒只补发一次）")
