-- TohsakaWrt Telegram Engine (High Performance & Resilient)
local M = {}

-- 注意：这两个 require 必须放在 with_back 之前。
-- Lua 是词法作用域，若 local core 声明在 with_back 之后，函数体里的 core 会解析成全局 nil。
local core = require("tohsakawrt.core")
local json = require("luci.jsonc")

-- Telegram 硬限制：callback_data 为 1~64 字节。
-- 超长时 Telegram 以 400 BUTTON_DATA_INVALID 拒绝【整条消息】（正文也发不出去），
-- 而调用方普遍忽略 send_msg 的返回值 → 用户看到的是"点了按钮毫无反应"。
-- 本项目动态拼接 callback_data 的三处都可能越界：
--   bot_sys.lua   direct_del:域名 / direct_add_do:域名（域名上限 253 字符）
--   bot_modem.lua do_band:频段串（用户可输入任意长度）
-- 故在唯一出口 with_back 统一丢弃超长按钮，牺牲单个按钮而不是整条消息。
-- 实测：71 字节的 callback_data 返回 {"ok":false,...,"description":"Bad Request: BUTTON_DATA_INVALID"}
local CB_LIMIT = 64

local function kb_sanitize(inline_kb)
    if type(inline_kb) ~= "table" then return inline_kb end
    local out = {}
    for _, row in ipairs(inline_kb) do
        if type(row) == "table" then
            local newrow = {}
            for _, btn in ipairs(row) do
                if type(btn) == "table" then
                    local cb = btn.callback_data
                    if cb == nil or #tostring(cb) <= CB_LIMIT then
                        newrow[#newrow + 1] = btn
                    else
                        core.log("Tg", string.format(
                            "丢弃超长 callback_data（%d > %d 字节，否则整条消息会被 Telegram 拒收）：%s",
                            #tostring(cb), CB_LIMIT, tostring(cb):sub(1, 60)))
                    end
                end
            end
            -- 整行按钮被丢空时不再输出空数组行（空行同样会被 Telegram 判为非法）
            if #newrow > 0 then out[#out + 1] = newrow end
        end
    end
    return out
end

-- 导航兜底：所有内联键盘若没有"返回"类按钮，自动补一个「⬅️ 返回看板」。
-- 这样每张子卡片都点得回去，且只在这里实现一份（不再逐张卡片手写）。
-- 已有返回（按钮文字含"返回"）或已有回看板按钮（refresh_status）时不重复添加。
-- 出口统一经过 kb_sanitize，保证任何调用点都不会因超长 callback_data 让整条消息失败。
function M.with_back(inline_kb)
    if type(inline_kb) ~= "table" then return inline_kb end
    for _, row in ipairs(inline_kb) do
        if type(row) == "table" then
            for _, btn in ipairs(row) do
                if type(btn) == "table" then
                    local txt = tostring(btn.text or "")
                    if btn.callback_data == "refresh_status" or txt:find("返回", 1, true) then
                        return kb_sanitize(inline_kb)
                    end
                end
            end
        end
    end
    inline_kb[#inline_kb + 1] = { { text = "⬅️ 返回看板", callback_data = "refresh_status" } }
    return kb_sanitize(inline_kb)
end

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
        { { text = "🌡️ 实时温度" }, { text = "📡 5G模组" } },
        { { text = "🔄 模组重载" }, { text = "📇 卡内号码" } }
    },
    resize_keyboard = true
}

-- Telegram 单条消息上限 4096 字符；超过会被整条拒收（历史上导致长输出静默丢失）
local MSG_LIMIT = 4000

-- 判断一段 HTML 的标签是否自平衡（只查常用且不跨段使用的标签）
local function html_balanced(s)
    for _, tag in ipairs({ "b", "i", "u", "s" }) do
        local o = select(2, s:gsub("<" .. tag .. ">", ""))
        local c = select(2, s:gsub("</" .. tag .. ">", ""))
        if o ~= c then return false end
    end
    local co = select(2, s:gsub("<code>", ""))
    local cc = select(2, s:gsub("</code>", ""))
    if co ~= cc then return false end
    return true
end

-- 按行拆分超长文本：项目里的卡片文本每行标签自平衡，故按行切分是安全的；
-- 万一某段不平衡，发送时会自动降级为纯文本，而不是让整条消息丢失
local function split_html(text, limit)
    limit = limit or MSG_LIMIT
    if #text <= limit then return { text } end

    local chunks, cur, cur_len = {}, {}, 0
    local function flush()
        if cur_len > 0 then
            chunks[#chunks + 1] = table.concat(cur, "\n")
            cur, cur_len = {}, 0
        end
    end

    for line in (text .. "\n"):gmatch("(.-)\n") do
        if #line > limit then
            flush()
            local rest = line
            while #rest > limit do
                chunks[#chunks + 1] = rest:sub(1, limit)
                rest = rest:sub(limit + 1)
            end
            cur[#cur + 1] = rest
            cur_len = #rest + 1
        else
            if cur_len + #line + 1 > limit then flush() end
            cur[#cur + 1] = line
            cur_len = cur_len + #line + 1
        end
    end
    flush()
    return chunks
end

local function api_request(method, payload, timeout, attempt)
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
    local ok, res = pcall(json.parse, out)
    if not ok then
        core.log("Tg", "API response parse error: " .. tostring(res))
        return nil, tostring(res)
    end
    if type(res) == "table" and res.ok == false then
        local desc = tostring(res.description or res.error_code)
        local code = tonumber(res.error_code)
        -- 429：按 Telegram 给出的 retry_after 等待后重试一次（原先直接失败、消息丢失）
        if code == 429 and (attempt or 0) < 1 then
            local wait = tonumber(res.parameters and res.parameters.retry_after) or 3
            if wait < 1 then wait = 1 end
            if wait > 15 then wait = 15 end
            core.log("Tg", string.format("被限流（429），等待 %d 秒后重试: %s", wait, desc))
            os.execute("sleep " .. tostring(wait))
            return api_request(method, payload, timeout, (attempt or 0) + 1)
        end
        -- 400 "can't parse entities"：正文里出现了非法 HTML（例如帮助文字写成 <域名>），
        -- Telegram 会拒收【整条消息】，用户看到的现象是"点了按钮毫无反应"。
        -- 兜底：去掉 parse_mode 重发一次 —— 格式会丢，但消息必须送达。
        -- 重发时 payload.parse_mode 已是 nil，不可能无限循环。
        if code == 400 and payload and payload.parse_mode
           and desc:find("parse entities", 1, true) then
            core.log("Tg", "HTML 解析失败，已去掉格式重发: " .. desc)
            local plain = {}
            for k, v in pairs(payload) do plain[k] = v end
            plain.parse_mode = nil
            return api_request(method, plain, timeout, (attempt or 0) + 1)
        end
        if code == 401 then
            core.log("Tg", "令牌无效（401），请检查 uci tohsakawrt-tgbot.main.token")
        elseif code == 409 then
            core.log("Tg", "getUpdates 冲突（409）：可能有另一个机器人实例在同时拉取")
        end
        core.log("Tg", "API error: " .. desc)
        return nil, desc
    end
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

    local chunks = split_html(text, MSG_LIMIT)
    local last = nil
    for i = 1, #chunks do
        local part = chunks[i]
        local payload = {
            chat_id = chat_id,
            text = part,
            disable_web_page_preview = true
        }
        -- 标签不平衡时降级为纯文本，宁可格式丢失也不能整条发不出去
        if html_balanced(part) then
            payload.parse_mode = "HTML"
        end
        if i == #chunks then
            -- 键盘挂在最后一段，按钮才会出现在最下方
            if inline_kb then
                payload.reply_markup = { inline_keyboard = M.with_back(inline_kb) }
            else
                payload.reply_markup = reply_kb or M.DEFAULT_KEYBOARD
            end
        end
        if i > 1 and payload.parse_mode then
            payload.text = string.format("<i>(续 %d/%d)</i>\n", i, #chunks) .. payload.text
        end
        last = api_request("sendMessage", payload, 10)
    end
    return last
end

function M.edit_msg(msg_id, text, inline_kb)
    local _, chat_id, enabled = get_creds()
    if not enabled or not chat_id then return nil end

    -- 编辑接口无法分片，超长只能截断（否则整条编辑失败，用户看到的是旧内容）
    local body = text
    local truncated = false
    if #body > MSG_LIMIT then
        body = body:sub(1, MSG_LIMIT - 30) .. "\n<i>…（内容过长，已截断）</i>"
        truncated = true
    end

    local payload = {
        chat_id = chat_id,
        message_id = tonumber(msg_id),
        text = body,
        disable_web_page_preview = true
    }
    if (not truncated) or html_balanced(body) then
        payload.parse_mode = "HTML"
    end

    if inline_kb == false then
        -- 显式清空键盘。关键：editMessageText 省略 reply_markup 时旧键盘会【保留】
        -- （实测返回的 Message 对象里 reply_markup 仍在），传空数组才会删除。
        -- 确认框点"取消"后若不主动清空，残留的"确认执行"按钮仍可点击 → 取消形同虚设。
        payload.reply_markup = { inline_keyboard = {} }
    elseif inline_kb then
        payload.reply_markup = { inline_keyboard = M.with_back(inline_kb) }
    end

    return api_request("editMessageText", payload, 8)
end

-- 一次连接内完成"应答按钮 + 更新消息"：省掉一次 TLS 握手（本机实测约 1 秒）
-- 返回 true = 两个请求都成功；false = 有请求失败；nil = 根本没发出去
function M.answer_and_edit(cb_id, toast, msg_id, text, inline_kb)
    local token, chat_id, enabled = get_creds()
    if not enabled or token == "" or not chat_id then return nil end
    if not msg_id then
        return M.answer_callback(cb_id, toast)
    end

    core.init()
    local stamp = string.format("/tmp/tohsakawrt/tg_%d_%d", os.time(), math.random(1000, 9999))
    local a_file = stamp .. "_cb.json"
    local b_file = stamp .. "_edit.json"

    local payload_b = {
        chat_id = chat_id,
        message_id = tonumber(msg_id),
        text = text,
        parse_mode = "HTML",
        disable_web_page_preview = true
    }
    if inline_kb == false then
        payload_b.reply_markup = { inline_keyboard = {} }
    elseif inline_kb then
        payload_b.reply_markup = { inline_keyboard = M.with_back(inline_kb) }
    end

    local fa = io.open(a_file, "w")
    local fb = fa and io.open(b_file, "w") or nil
    if not fa or not fb then
        if fa then fa:close() end
        if fb then fb:close() end
        os.remove(a_file)
        os.remove(b_file)
        return nil
    end
    fa:write(json.stringify({ callback_query_id = tostring(cb_id), text = toast or "" }))
    fa:close()
    fb:write(json.stringify(payload_b))
    fb:close()

    local base = string.format("https://api.telegram.org/bot%s", token)
    local cmd = string.format(
        "curl -4 --http1.1 --connect-timeout 4 -s -m 5 -X POST -H 'Content-Type: application/json' --data-binary @%s '%s/answerCallbackQuery' " ..
        "--next -4 --http1.1 --connect-timeout 4 -s -m 10 -X POST -H 'Content-Type: application/json' --data-binary @%s '%s/editMessageText'",
        a_file, base, b_file, base)
    local out = core.exec(cmd)
    os.remove(a_file)
    os.remove(b_file)

    if not out or out == "" then
        core.log("Tg", "answer_and_edit: empty response")
        return nil
    end
    if out:find('"ok":false', 1, true) then
        core.log("Tg", "answer_and_edit: 有请求失败: " .. out:sub(1, 160))
        return false
    end
    return true
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
