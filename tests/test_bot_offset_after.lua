package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

-- 第三笔欠账：偏移量必须在"处理完成之后"落盘。
-- 处理中重启若已提前落盘，这条指令就永远不会再收到（永久丢失）。

local configured_chat_id = "123456"
local events, logs = {}, {}
local uci_calls = {}
local update_calls = 0

package.loaded["tohsakawrt.bot"] = nil
package.preload["tohsakawrt.core"] = function()
    return {
        get_uci = function(cfg, sec, option, default)
            local val = default
            if option == "enabled" then val = "1" end
            if option == "token" then val = "test-token" end
            if option == "chat_id" then val = configured_chat_id end
            uci_calls[#uci_calls + 1] = string.format("%s.%s.%s -> %s",
                tostring(cfg), tostring(sec), tostring(option), tostring(val))
            return val
        end,
        get_state = function(_, default) return default end,
        set_state = function(key) events[#events + 1] = "offset:" .. tostring(key) end,
        log = function(tag, msg) logs[#logs + 1] = { tag = tag, msg = msg } end,
        exec = function() return "" end
    }
end
package.preload["tohsakawrt.tg"] = function()
    return {
        get_updates = function()
            update_calls = update_calls + 1
            if update_calls == 1 then return { result = {} } end
            if update_calls == 2 then
                return {
                    result = {
                        {
                            update_id = 1,
                            message = {
                                -- 必须带 type 与 from：机器人启用了发送者鉴权，
                                -- 未配置 user_id 时只接受私聊消息（真实 Telegram 消息必然带这两项）
                                chat = { id = tonumber(configured_chat_id), type = "private" },
                                from = { id = tonumber(configured_chat_id) },
                                text = "/help"
                            }
                        }
                    }
                }
            end
            error("__TEST_STOP__")
        end,
        send_msg = function() events[#events + 1] = "send_msg" end,
        send_chat_action = function() end
    }
end
package.preload["tohsakawrt.system"] = function() return {} end
package.preload["tohsakawrt.modem"] = function() return {} end
package.preload["tohsakawrt.clash"] = function() return {} end
package.preload["tohsakawrt.esim"] = function() return {} end

local bot = require("tohsakawrt.bot")
local ok, err = pcall(bot.run)
assert(not ok and tostring(err):find("__TEST_STOP__", 1, true),
    "bot.run 只应在 get_updates 的哨兵异常处停止")

local function dump_events()
    print("  事件顺序: " .. (#events > 0 and table.concat(events, ", ") or "(空)"))
    print("  UCI 读取记录:")
    for i, c in ipairs(uci_calls) do print(string.format("    [%d] %s", i, c)) end
    for i, l in ipairs(logs) do
        print(string.format("  日志[%d] %s: %s", i, tostring(l.tag), tostring(l.msg)))
    end
end

local send_at, offset_at
for i, e in ipairs(events) do
    if e == "send_msg" and not send_at then send_at = i end
    if e:find("^offset:") and not offset_at then offset_at = i end
end
if not send_at or not offset_at then dump_events() end
assert(send_at, "授权指令必须被派发并回复（未收到 send_msg 事件）")
assert(offset_at, "处理完成后必须落盘偏移量")
assert(send_at < offset_at,
    string.format("偏移量必须在处理完成之后落盘（实际顺序：%s 在第 %d 位，落盘在第 %d 位）",
        "send_msg", send_at, offset_at))

print("PASS: 偏移量在处理完成之后才落盘（处理中重启最多重做一次，不会丢指令）")
