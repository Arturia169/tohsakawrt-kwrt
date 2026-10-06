package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 真实的 Telegram 响应：answerCallbackQuery 与 editMessageText 的 JSON 会拼在一起返回
local OK = '{"ok":true,"result":true}'
local PARTIAL_FAIL = '{"ok":true,"result":true}{"ok":false,"error_code":400,"description":"Bad Request: message is not modified"}'

local response, last_cmd = nil, nil
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
        exec = function(cmd) last_cmd = cmd; return response end,
        log = function(tag, message) logs[#logs + 1] = { tag = tag, message = message } end
    }
end
package.preload["luci.jsonc"] = function()
    return {
        stringify = function() return "{}" end,
        parse = function(raw)
            if raw:find('"ok":false', 1, true) then
                return { ok = false, description = "Bad Request: message is not modified" }
            end
            return { ok = true, result = { message_id = 19 } }
        end
    }
end

os.execute("mkdir -p /tmp/tohsakawrt")
local tg = require("tohsakawrt.tg")

-- 情形 1：两个请求都成功，应只发一条 curl 且包含 --next
response = OK .. OK
local ok = tg.answer_and_edit("cb-1", "🔄 正在刷新看板...", 555, "正文", { { { text = "x", callback_data = "y" } } })
assert(ok == true, "两个请求都成功时必须返回 true")
assert(last_cmd:find("answerCallbackQuery", 1, true), "合并请求必须包含应答按钮的端点")
assert(last_cmd:find("editMessageText", 1, true), "合并请求必须包含更新消息的端点")
assert(last_cmd:find("--next", 1, true), "两个请求必须用 --next 复用同一条连接")
assert(select(2, last_cmd:gsub("%-%-data%-binary", "")) == 2, "两个请求必须各自带一份载荷文件")
assert(#logs == 0, "成功时不应留下错误日志")

-- 情形 2：其中一个请求失败（例如内容未变化），必须返回 false 并留下日志
response = PARTIAL_FAIL
local failed = tg.answer_and_edit("cb-2", "toast", 556, "正文", nil)
assert(failed == false, "有请求失败时必须返回 false")
assert(#logs == 1 and logs[1].tag == "Tg", "失败时必须记录日志")

-- 情形 3：拿不到 message_id 时退回普通的应答，不带 --next
response = OK
local fallback = tg.answer_and_edit("cb-3", "toast", nil, "正文", nil)
assert(fallback ~= nil, "缺少 message_id 时应退回普通应答而不是失败")
assert(last_cmd:find("answerCallbackQuery", 1, true), "退回路径仍应应答按钮")
assert(not last_cmd:find("--next", 1, true), "退回路径不应使用 --next")

-- 情形 4：临时载荷文件必须清理干净
local leftovers = 0
local pipe = io.popen("ls /tmp/tohsakawrt/tg_*_cb.json 2>/dev/null | wc -l")
if pipe then leftovers = tonumber(pipe:read("*a")) or 0; pipe:close() end
assert(leftovers == 0, "临时载荷文件必须全部清理，实际残留 " .. tostring(leftovers))

print("PASS: answer_and_edit 合并两个请求为一条连接，失败可识别，临时文件清理干净")
