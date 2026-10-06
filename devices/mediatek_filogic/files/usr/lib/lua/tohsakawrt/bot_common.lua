-- TohsakaWrt Bot 共享零件：被 bot.lua 与各 bot_*.lua 模块共用
-- 只放"多个模块都要用"的东西；具体功能实现留在各自模块里。
local M = {}

local core = require("tohsakawrt.core")
local tg = require("tohsakawrt.tg")
local sys = require("tohsakawrt.system")
local modem = require("tohsakawrt.modem")
local clash = require("tohsakawrt.clash")
local esim = require("tohsakawrt.esim")
local nixio_ok, nixio = pcall(require, "nixio")
if not nixio_ok then nixio = nil end

M.core, M.tg, M.sys, M.modem, M.clash, M.esim, M.nixio = core, tg, sys, modem, clash, esim, nixio

function M.html_escape(value)
    local escaped = tostring(value or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    return escaped
end

function M.ask_confirm(title, desc, impact, confirm_action)
    local text = string.format([[⚠️ <b>敏感操作确认</b>
━━━━━━━━━━━━━━━━━━
<b>操作项目</b>：<code>%s</code>
<b>操作目标</b>：<code>%s</code>
<b>影响评估</b>：%s

❓ <b>请确认是否真的执行？</b>

🕰️ <i>%s</i>]], M.html_escape(title), M.html_escape(desc), M.html_escape(impact), os.date("%Y-%m-%d %H:%M:%S"))
    local inline_kb = {
        {
            { text = "🔴 确认执行", callback_data = confirm_action },
            { text = "🟢 取消操作", callback_data = "cancel_action" }
        }
    }
    tg.send_msg(text, inline_kb)
end

-- 计时用：/proc/uptime 精确到 0.01 秒（os.time 只有秒级，量不出按钮快慢）
function M.now_ms()
    local f = io.open("/proc/uptime", "r")
    if not f then return os.time() * 1000 end
    local raw = f:read("*a")
    f:close()
    local sec = tonumber(raw and raw:match("^(%d+%.?%d*)"))
    if not sec then return os.time() * 1000 end
    return math.floor(sec * 1000)
end

-- 注意语义：uci 未配置时按"已启用"处理（这是原有行为，不要改成默认关闭）
function M.esim_enabled()
    return core.get_uci("tohsakawrt-tgbot", "main", "esim_enabled", "1") ~= "0"
end

return M
