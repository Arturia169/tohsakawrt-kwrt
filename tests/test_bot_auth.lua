package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;" .. package.path

local configured_chat_id = "123456"
local configured_user_id = ""
local update_response
local update_calls
local sent_messages
local chat_actions
local logs
local state_writes

local function install_bot_stubs()
    update_response = nil
    update_calls = 0
    sent_messages = 0
    chat_actions = 0
    logs = {}
    state_writes = 0

    package.loaded["tohsakawrt.bot"] = nil
    package.loaded["tohsakawrt.bot_common"] = nil
    package.preload["tohsakawrt.core"] = function()
        return {
            get_uci = function(_, _, option, default)
                if option == "enabled" then return "1" end
                if option == "token" then return "test-token" end
                if option == "chat_id" then return configured_chat_id end
                if option == "user_id" then return configured_user_id end
                return default
            end,
            get_state = function(_, default) return default end,
            set_state = function() state_writes = state_writes + 1 end,
            log = function(tag, msg) logs[#logs + 1] = { tag = tag, msg = msg } end,
            exec = function() return "" end
        }
    end
    package.preload["tohsakawrt.tg"] = function()
        return {
            get_updates = function()
                update_calls = update_calls + 1
                if update_calls == 1 then return { result = {} } end
                if update_calls == 2 then return update_response end
                error("__TEST_STOP__")
            end,
            send_msg = function() sent_messages = sent_messages + 1 end,
            send_chat_action = function() chat_actions = chat_actions + 1 end,
            answer_callback = function() error("unauthorized callback was answered") end
        }
    end
    package.preload["tohsakawrt.system"] = function() return {} end
    package.preload["tohsakawrt.modem"] = function() return {} end
    package.preload["tohsakawrt.clash"] = function() return {} end
    package.preload["tohsakawrt.esim"] = function() return {} end
end

-- opts.chat_type 默认 private；opts.from_id 默认等于 chat id（私聊语义）
local function run_with_message(source_chat_id, opts)
    opts = opts or {}
    install_bot_stubs()
    update_response = {
        result = {
            {
                update_id = 1,
                message = {
                    chat = { id = source_chat_id, type = opts.chat_type or "private" },
                    from = { id = opts.from_id or source_chat_id },
                    text = "/help"
                }
            }
        }
    }
    local bot = require("tohsakawrt.bot")
    local ok, err = pcall(bot.run)
    assert(not ok and tostring(err):find("__TEST_STOP__", 1, true),
        "bot.run must stop only when the get_updates sentinel is raised")
end

run_with_message("999999")
assert(sent_messages == 0, "unauthorized message must not send a message")
assert(chat_actions == 0, "unauthorized message must not send a chat action")
assert(state_writes == 1, "unauthorized update must advance the offset or it can silence the bot")
assert(#logs == 2 and logs[2].msg == "Rejected update from unauthorized chat",
    "unauthorized message must only produce a short rejection log")

run_with_message(tonumber(configured_chat_id))
assert(chat_actions == 1, "authorized message must be dispatched")
assert(sent_messages == 1, "authorized /help command must send its response")
assert(state_writes == 1, "authorized message must update the polling offset")

-- 新增断言：user_id 白名单（配置后按发送者身份严格校验）
configured_user_id = "555000"
run_with_message(configured_chat_id, { from_id = "999000" })
assert(sent_messages == 0, "配置 user_id 后，发送者不匹配必须拒绝")
assert(chat_actions == 0, "被拒绝的发送者不得触发任何动作")

configured_user_id = "555000"
run_with_message(configured_chat_id, { from_id = "555000" })
assert(chat_actions == 1, "配置 user_id 且发送者匹配必须放行")
assert(sent_messages == 1, "放行后 /help 必须正常回复")

-- 新增断言：未配置 user_id 时，群聊必须拒绝（防任意群成员控制路由器）
configured_user_id = ""
run_with_message(configured_chat_id, { chat_type = "supergroup", from_id = "777000" })
assert(sent_messages == 0, "群聊且未配置 user_id 必须拒绝")

-- 新增断言：群聊配置了 user_id 且匹配则放行（保留群聊可用性）
configured_user_id = "777000"
run_with_message(configured_chat_id, { chat_type = "supergroup", from_id = "777000" })
assert(chat_actions == 1, "群聊配置 user_id 且匹配必须放行")

-- 新增断言：私聊但 from.id 与 chat.id 不一致（异常构造）必须拒绝
configured_user_id = ""
run_with_message(configured_chat_id, { chat_type = "private", from_id = "424242" })
assert(sent_messages == 0, "私聊下发送者与 chat 不一致必须拒绝")

local captured_command
local original_execute = os.execute
os.execute = function(command) captured_command = command end
package.loaded["tohsakawrt.core"] = nil
package.preload["tohsakawrt.core"] = nil
package.preload["uci"] = function() return { cursor = function() return {} end } end
package.preload["luci.jsonc"] = function() return {} end
local core = require("tohsakawrt.core")
core.log("Tohsaka-Bot", "Command: $(reboot) `id` ' \"\n\r\t")
os.execute = original_execute
assert(captured_command == "logger -t 'Tohsaka-Bot' 'Command: $(reboot) `id` '\\'' \"   '",
    "log command must exactly quote shell metacharacters and normalize control whitespace")

print("PASS: bot rejects unauthorized chats/senders, dispatches the configured chat, and safely quotes logs")
