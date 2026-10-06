package.path = "devices/mediatek_filogic/files/usr/lib/lua/?.lua;devices/mediatek_filogic/files/usr/lib/lua/?/init.lua;files/usr/lib/lua/?.lua;files/usr/lib/lua/?/init.lua;" .. package.path

local configured_chat_id = "123456"
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
    package.preload["tohsakawrt.core"] = function()
        return {
            get_uci = function(_, _, option, default)
                if option == "enabled" then return "1" end
                if option == "token" then return "test-token" end
                if option == "chat_id" then return configured_chat_id end
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

local function run_with_message(source_chat_id)
    install_bot_stubs()
    update_response = {
        result = {
            {
                update_id = 1,
                message = { chat = { id = source_chat_id }, text = "/help" }
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

print("PASS: bot rejects unauthorized chats, dispatches the configured chat, and safely quotes logs")
