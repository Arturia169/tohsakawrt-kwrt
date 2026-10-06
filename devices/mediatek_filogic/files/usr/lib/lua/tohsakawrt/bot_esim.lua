-- TohsakaWrt Bot：卡内号码与 eSIM 任务（读卡、启停用、切换配置）
-- 共享零件来自 bot_common；本模块只放这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape, ask_confirm = bc.html_escape, bc.ask_confirm

local M = {}

function M.cmd_cards(msg_id)
    if not esim_enabled() then
        if msg_id then tg.edit_msg(msg_id, "⚠️ 功能已停用") else tg.send_msg("⚠️ 功能已停用") end
        return
    end
    local profiles, err, detail = esim.list()
    if not profiles then
        local hint = html_escape(esim.list_hint(err, detail))
        local failure = "⚠️ <b>读取卡内号码失败</b>：" .. hint
        if msg_id then tg.edit_msg(msg_id, failure)
        else tg.send_msg(failure) end
        return
    end
    local text, kb = esim.card_text(profiles)
    text = text:gsub("(电话: <code>)([^\n]*)(</code>)", function(prefix, value, suffix)
        return prefix .. html_escape(value) .. suffix
    end)
    text = text:gsub("⚪", "ℹ️")
    text = text:gsub("电话:", "<b>电话</b>：")
    text = text:gsub("卡号:", "<b>卡号</b>：")
    text = text .. "\n\n🕰️ <i>" .. os.date("%Y-%m-%d %H:%M:%S") .. "</i>"
    if msg_id then tg.edit_msg(msg_id, text, kb) else tg.send_msg(text, kb) end
end

function M.new_job_id()
    return tostring(os.time()) .. tostring(math.random(100, 999))
end

function M.start_esim_job(kind, target, display_name, message_id, extra_arg)
    if not esim_enabled() then tg.send_msg("⚠️ 功能已停用"); return end
    local id = M.new_job_id()
    local action = (kind == "reload" and "正在重载 5G 模组…")
        or (kind == "download" and "正在连接服务器下载写卡…")
        or "正在切换号码…"
    local warning = ""
    local main_uplink = (kind == "switch" or kind == "reload") and sys.uplink_status().type == "5g"
    if main_uplink then
        warning = "\n⚠️ 模组当前是主出口，期间会断网约 2 分钟"
    end
    local pending = "⏳ <b>" .. action .. "</b>" .. warning
    local pending_kb = {{ { text = "查看结果", callback_data = "esim_result:" .. id } }}
    if message_id then tg.edit_msg(message_id, pending, pending_kb)
    else tg.send_msg(pending, pending_kb) end
    if not esim.start_job(kind, id, target, display_name, main_uplink, extra_arg, message_id) then
        tg.send_msg("⚠️ 后台任务启动失败，请稍后重试。")
        return
    end
end

function M.switch_profile(selector)
    if not esim_enabled() then tg.send_msg("⚠️ 功能已停用"); return end
    local profiles, err, detail = esim.list()
    if not profiles then
        local hint = html_escape(esim.list_hint(err, detail))
        tg.send_msg("⚠️ <b>读取卡内号码失败</b>：" .. hint)
        return
    end
    local profile, err = esim.resolve(profiles, selector)
    if err == "full_iccid" then tg.send_msg("⚠️ 请使用序号、名称或掩码选择号码。"); return end
    if not profile then tg.send_msg("⚠️ 未找到匹配号码，请先查看卡内号码。"); return end
    if profile.profileState == "enabled" then
        tg.send_msg("ℹ️ 该号码本来就是生效中的，未做改动。")
        M.cmd_cards()
        return
    end
    M.start_esim_job("switch", profile.iccid, profile.profileNickname or profile.serviceProviderName or profile.profileName)
end

return M
