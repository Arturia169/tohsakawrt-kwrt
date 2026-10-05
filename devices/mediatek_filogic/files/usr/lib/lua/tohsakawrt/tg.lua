-- TohsakaWrt Telegram Engine (High Performance & Resilient)
local M = {}

local core = require("tohsakawrt.core")
local json = require("luci.jsonc")

local CONFIG_NAME = "tohsakawrt-tgbot"

local _creds_cache = nil
local _creds_cache_ts = 0

local function get_creds(force)
    local now = os.time()
    if not force and _creds_cache and (now - _creds_cache_ts) < 60 then
        return _creds_cache.token, _creds_cache.chat_id, _creds_cache.enabled
    end

    local token = core.get_uci(CONFIG_NAME, "main", "token", "")
    local chat_id = core.get_uci(CONFIG_NAME, "main", "chat_id", "")
    local enabled = core.get_uci(CONFIG_NAME, "main", "enabled", "0") == "1"

    _creds_cache = { token = token, chat_id = chat_id, enabled = enabled }
    _creds_cache_ts = now
    return token, chat_id, enabled
end

M.DEFAULT_KEYBOARD = {
    keyboard = {
        { { text = "📊 系统状态" }, { text = "🔀 出口切网" } },
        { { text = "🧭 节点分流" }, { text = "🔀 分流模式" } },
        { { text = "👥 在线设备" }, { text = "🌐 外网详情" } },
        { { text = "🎯 直连白名单" }, { text = "🩺 双向体检" } },
        { { text = "🌡️ 实时温度" }, { text = "📡 5G模组" } }
    },
    resize_keyboard = true
}

local function api_request(method, payload, timeout)
    local token, _, enabled = get_creds()
    if not enabled or token == "" then return nil, "Bot not enabled or token missing" end

    timeout = timeout or 8
    local url = string.format("https://api.telegram.org/bot%s/%s", token, method)
    local json_body = payload and json.stringify(payload) or "{}"

    core.init()
    local tmp_payload = string.format("/tmp/tohsakawrt/tg_%d_%d.json", os.time(), math.random(1000, 9999))
    local f = io.open(tmp_payload, "w")
    if f then
        f:write(json_body)
        f:close()
    else
        return nil, "Failed to create temp request file"
    end

    local exec_cmd = string.format("curl -4 --http1.1 --connect-timeout 4 -s -m %d -X POST -H 'Content-Type: application/json' --data-binary @%s '%s'", timeout, tmp_payload, url)
    local out = core.exec(exec_cmd)
    os.remove(tmp_payload)

    if not out or out == "" then return nil, "Empty response" end
    local res = json.parse(out)
    return res
end

function M.send_chat_action(action)
    action = action or "typing"
    local _, chat_id, enabled = get_creds()
    if not enabled or not chat_id then return nil end
    local payload = {
        chat_id = chat_id,
        action = action
    }
    return api_request("sendChatAction", payload, 3)
end

function M.send_msg(text, inline_kb, reply_kb)
    local _, chat_id, enabled = get_creds()
    if not enabled or not chat_id then return nil end

    local payload = {
        chat_id = chat_id,
        text = text,
        parse_mode = "HTML",
        disable_web_page_preview = true
    }

    if inline_kb then
        payload.reply_markup = { inline_keyboard = inline_kb }
    else
        payload.reply_markup = reply_kb or M.DEFAULT_KEYBOARD
    end

    return api_request("sendMessage", payload, 10)
end

function M.edit_msg(msg_id, text, inline_kb)
    local _, chat_id, enabled = get_creds()
    if not enabled or not chat_id then return nil end

    local payload = {
        chat_id = chat_id,
        message_id = tonumber(msg_id),
        text = text,
        parse_mode = "HTML",
        disable_web_page_preview = true
    }

    if inline_kb then
        payload.reply_markup = { inline_keyboard = inline_kb }
    end

    return api_request("editMessageText", payload, 8)
end

function M.answer_callback(cb_id, text)
    local payload = {
        callback_query_id = tostring(cb_id),
        text = text or ""
    }
    return api_request("answerCallbackQuery", payload, 4)
end

function M.get_updates(offset, timeout)
    local token, _, enabled = get_creds()
    if not enabled or token == "" then return nil end

    timeout = timeout or 8
    local url = string.format("https://api.telegram.org/bot%s/getUpdates?offset=%s&timeout=%d", token, tostring(offset or 0), timeout)
    local cmd = string.format("curl -4 --http1.1 --connect-timeout 4 -s -m %d '%s'", timeout + 3, url)
    local raw = core.exec(cmd)
    if not raw or raw == "" then return nil end
    return json.parse(raw)
end

return M
