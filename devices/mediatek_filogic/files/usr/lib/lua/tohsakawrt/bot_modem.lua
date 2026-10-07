-- TohsakaWrt Bot：模组与短信（模组状态卡、短信列表与验证码提取）
-- 共享零件来自 bot_common；本模块只放这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape, ask_confirm = bc.html_escape, bc.ask_confirm

local M = {}

function M.cmd_modem(msg_id, cb_id)
    local m = modem.info()
    local usb0 = sys.usb0_ip()
    local port = modem.get_port and modem.get_port() or "/dev/ttyUSB3"
    local has_at = nixio and nixio.fs and nixio.fs.stat(port)
    local modem_status = has_at and "✅ 已连接" or "ℹ️ 未检测到"
    local now = os.date("%Y-%m-%d %H:%M:%S")

    -- 信号强度仪表状态
    local rsrp_line = "未获取"
    if m.rsrp then
        local r = m.rsrp_num or -999
        local r_icon = "🟢"
        local r_eval = "极佳"
        if r <= -110 then r_icon = "🔴"; r_eval = "极差"
        elseif r <= -100 then r_icon = "🟠"; r_eval = "较弱"
        elseif r <= -85 then r_icon = "🟡"; r_eval = "中等"
        elseif r <= -75 then r_icon = "🟢"; r_eval = "良好"
        else r_icon = "🟢"; r_eval = "极佳" end
        rsrp_line = string.format("<code>%s</code> (%s) %s", html_escape(m.rsrp), r_eval, r_icon)
    end

    local sinr_line = "未获取"
    if m.sinr then
        local s = m.sinr_num or -999
        local s_icon = "🟢"
        local s_eval = "极佳"
        if s <= 0 then s_icon = "🔴"; s_eval = "极差"
        elseif s <= 5 then s_icon = "🟠"; s_eval = "较弱"
        elseif s <= 13 then s_icon = "🟡"; s_eval = "良好"
        else s_icon = "🟢"; s_eval = "极佳" end
        sinr_line = string.format("<code>%s</code> (%s) %s", html_escape(m.sinr), s_eval, s_icon)
    end

    local rsrq_line = m.rsrq and string.format("<code>%s</code>", html_escape(m.rsrq)) or "未获取"
    local temp_line = m.temp and string.format("<code>%s</code> 🟢", html_escape(m.temp)) or "未获取"
    local qci_line = m.qci and string.format("<code>5QI %s (标准移动宽带)</code>", html_escape(m.qci)) or "未获取"
    local ambr_line = (m.ambr_dl and m.ambr_ul) and string.format("<code>下行 %s / 上行 %s</code>", html_escape(m.ambr_dl), html_escape(m.ambr_ul)) or "未获取"

    local cell_extra = ""
    if m.pci and m.cell_id then
        cell_extra = string.format("\n📍 <b>小区标识</b>：PCI <code>%s</code> · CellID <code>%s</code>", html_escape(m.pci), html_escape(m.cell_id))
    end

    local text = string.format([[📡 <b>5G 蜂窝模块 (RM500Q-GL)</b>

━━━━━━━━━━━━━━━━━━
📟 <b>硬件状态</b>：%s (<code>%s</code>)
🏢 <b>运营商</b>：<code>%s</code>
📶 <b>网络制式</b>：<code>%s</code>
📻 <b>工作频段</b>：<code>%s</code>
🌡️ <b>模组温度</b>：%s
━━━━━━━━━━━━━━━━━━
📊 <b>信号质量指示</b>：
├ 接收功率 (RSRP)：%s
├ 信号质量 (RSRQ)：%s
└ 信噪比 (SINR)：%s%s
━━━━━━━━━━━━━━━━━━
🚀 <b>网络业务签约</b>：
├ 业务等级：%s
└ 签约速率：%s
━━━━━━━━━━━━━━━━━━
🌐 <b>蜂窝内网</b>：<code>%s</code>
🔌 <b>USB 网卡</b>：<code>%s</code>
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]],
        modem_status, html_escape(port),
        html_escape(m.oper),
        html_escape(m.mode),
        html_escape(m.band),
        temp_line,
        rsrp_line,
        rsrq_line,
        sinr_line,
        cell_extra,
        qci_line,
        ambr_line,
        html_escape(m.sim_ip),
        html_escape(usb0),
        html_escape(now)
    )

    local inline_kb = {
        {
            { text = "🔄 刷新状态", callback_data = "refresh_modem" },
            { text = "✉️ 查收短信", callback_data = "show_sms" }
        },
        {
            { text = "📇 卡内号码", callback_data = "refresh_cards" },
            { text = "🔄 重载模组", callback_data = "do_modem_reload" }
        },
        {
            { text = "📈 信号趋势", callback_data = "signal_trend" },
            { text = "📻 频段设置", callback_data = "band_menu" }
        }
    }

    if msg_id and cb_id then
        return tg.answer_and_edit(cb_id, "正在刷新模组状态...", msg_id, text, inline_kb)
    end
    if msg_id then
        return tg.edit_msg(msg_id, text, inline_kb)
    end
    return tg.send_msg(text, inline_kb)
end
-- 频段设置的常用组合（按需增删；都用冒号分隔的 NR 频段号）
local BAND_PRESETS = {
    { label = "🔒 只锁 n78", list = "78" },
    { label = "🔒 锁 n78 + n1", list = "78:1" },
    { label = "🔒 锁 n78 + n41", list = "78:41" }
}

-- 把 "1:2:3:...:79" 归纳成可读文本
local function band_summary(raw)
    raw = tostring(raw or ""):gsub("%s+$", "")
    if raw == "" then return "读取失败" end
    local names, n = {}, 0
    for b in raw:gmatch("[^:]+") do
        n = n + 1
        if n <= 4 then names[#names + 1] = "n" .. b end
    end
    if n == 0 then return "读取失败" end
    if n > 4 then return string.format("%s 等 %d 个频段", table.concat(names, " / "), n) end
    return table.concat(names, " / ")
end

function M.cmd_band_menu(msg_id, cb_id)
    local raw = core.exec_line("/usr/bin/tohsakawrt-band show 2>/dev/null") or ""
    local note = core.exec_line("/usr/bin/tohsakawrt-band note 2>/dev/null") or ""
    note = tostring(note):gsub("%s+$", "")
    local m = modem.info()
    local text = string.format([[📻 <b>5G 频段设置</b>

━━━━━━━━━━━━━━━━━━
⚙️ <b>当前允许频段</b>：<code>%s</code>
📡 <b>当前驻留频段</b>：<code>%s</code>
%s━━━━━━━━━━━━━━━━━━
⚠️ <i>锁定后模组会重新注册网络（5G 短暂断开约 1 分钟）。若 %s 分钟内探测不通，
系统会**自动恢复**原来的设置并通知你，不会把你留在没有信号的状态。</i>
🕰️ <i>%s</i>]],
        html_escape(band_summary(raw)),
        html_escape(tostring(m.band or "未知")),
        (note ~= "" and ("↩️ <b>上次自动回退</b>：" .. html_escape(note) .. "\n") or ""),
        "3", os.date("%Y-%m-%d %H:%M:%S"))

    local row1, row2 = {}, {}
    for _, p in ipairs(BAND_PRESETS) do
        row1[#row1 + 1] = { text = p.label, callback_data = "band_confirm:" .. p.list }
    end
    row2[#row2 + 1] = { text = "🔓 恢复原设置", callback_data = "band_restore" }
    row2[#row2 + 1] = { text = "📡 返回模组", callback_data = "refresh_modem" }

    local kb = { row1, row2 }
    if msg_id and cb_id then
        return tg.answer_and_edit(cb_id, "正在读取频段设置...", msg_id, text, kb)
    end
    if msg_id then return tg.edit_msg(msg_id, text, kb) end
    return tg.send_msg(text, kb)
end

-- 锁定前二次确认（会短暂断网，必须让用户明确同意）
function M.band_confirm(list, msg_id, cb_id)
    list = tostring(list or "")
    if not list:match("^[0-9]+(:[0-9]+)*$") then
        if cb_id then tg.answer_callback(cb_id, "频段格式不正确") end
        return tg.send_msg("⚠️ <b>频段格式不正确</b>\n\n<i>应形如 <code>78</code> 或 <code>78:1</code>。</i>")
    end
    local pretty = {}
    for b in list:gmatch("[^:]+") do pretty[#pretty + 1] = "n" .. b end
    local subject = table.concat(pretty, " + ")
    local impact = "锁定后模组将重新注册网络，5G 会短暂断开约 1 分钟；" ..
        "若 3 分钟内探测不通，系统会自动恢复原设置并通知你。"
    if cb_id then tg.answer_callback(cb_id, "请确认") end
    return ask_confirm("锁定 5G 频段", subject, impact, "do_band:" .. list)
end

-- 真正执行锁定
function M.band_lock(list, msg_id, cb_id)
    local out = core.exec_line("/usr/bin/tohsakawrt-band lock " .. tostring(list) .. " 2>/dev/null") or ""
    out = tostring(out):gsub("%s+$", "")
    local ok = (out == "OK_LOCKED")
    local body
    if ok then
        local pretty = {}
        for b in tostring(list):gmatch("[^:]+") do pretty[#pretty + 1] = "n" .. b end
        body = string.format([[✅ <b>已提交频段锁定</b>

━━━━━━━━━━━━━━━━━━
📻 <b>锁定频段</b>：<code>%s</code>
⏳ <b>观察期</b>：3 分钟（期间 5G 会重新注册）
🛡️ <b>保底</b>：探测不通会自动恢复原设置并通知你
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], html_escape(table.concat(pretty, " + ")), os.date("%Y-%m-%d %H:%M:%S"))
    else
        body = string.format("⚠️ <b>频段锁定失败</b>\n\n<code>%s</code>\n\n<i>未做任何改动。</i>",
            html_escape(out ~= "" and out or "无返回（模组可能未就绪）"))
    end
    local kb = { { { text = "📻 频段设置", callback_data = "band_menu" } } }
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, ok and "已提交锁定" or "锁定失败", msg_id, body, kb) end
    if msg_id then return tg.edit_msg(msg_id, body, kb) end
    return tg.send_msg(body, kb)
end

function M.band_restore(msg_id, cb_id)
    local out = core.exec_line("/usr/bin/tohsakawrt-band restore 2>/dev/null") or ""
    out = tostring(out):gsub("%s+$", "")
    local ok = (out == "OK_RESTORED")
    local body = ok and "🔓 <b>已恢复原频段设置</b>\n\n<i>模组会重新注册网络，约 1 分钟。</i>"
        or string.format("⚠️ <b>恢复失败</b>\n\n<code>%s</code>", html_escape(out ~= "" and out or "无返回"))
    local kb = { { { text = "📻 频段设置", callback_data = "band_menu" } } }
    if msg_id and cb_id then return tg.answer_and_edit(cb_id, ok and "已恢复" or "恢复失败", msg_id, body, kb) end
    if msg_id then return tg.edit_msg(msg_id, body, kb) end
    return tg.send_msg(body, kb)
end

-- 5G 信号趋势：交给脚本汇总（解析与格式化只有一份实现），这里只负责转发
function M.cmd_signal_trend(msg_id, cb_id)
    local body = core.exec("/usr/bin/tohsakawrt-signal-log show 60 2>/dev/null") or ""
    body = tostring(body):gsub("%s+$", "")
    if body == "" then
        body = "📈 <b>5G 信号趋势</b>\n\n<i>暂时读不到趋势数据（记录器可能刚开始运行）。</i>"
    end
    local kb = {
        {
            { text = "🔄 刷新趋势", callback_data = "signal_trend" },
            { text = "📡 返回模组", callback_data = "refresh_modem" }
        }
    }
    if msg_id and cb_id then
        return tg.answer_and_edit(cb_id, "正在统计信号趋势...", msg_id, body, kb)
    end
    if msg_id then return tg.edit_msg(msg_id, body, kb) end
    return tg.send_msg(body, kb)
end

function M.cmd_sms(limit, msg_id, cb_id)
    limit = tonumber(limit) or 3
    if limit > 10 then limit = 10 end
    if limit < 1 then limit = 1 end

    local list = modem.sms_list and modem.sms_list("ME", limit) or {}
    local now = os.date("%Y-%m-%d %H:%M:%S")

    if not list or #list == 0 then
        local text = string.format([[✉️ <b>5G 模组短信收件箱</b>

━━━━━━━━━━━━━━━━━━
📭 <b>当前收件箱为空</b>
<i>未在模组设备存储中检测到有效短消息。</i>
━━━━━━━━━━━━━━━━━━
🕰️ <i>%s</i>]], html_escape(now))

        local inline_kb = {
            {
                { text = "🔄 刷新短信", callback_data = "refresh_sms" },
                { text = "📡 模组状态", callback_data = "refresh_modem" }
            }
        }
        if msg_id and cb_id then
            return tg.answer_and_edit(cb_id, "正在读取最新短信...", msg_id, text, inline_kb)
        end
        if msg_id then return tg.edit_msg(msg_id, text, inline_kb) end
        return tg.send_msg(text, inline_kb)
    end

    local items = {}
    for i, m in ipairs(list) do
        local code_part = ""
        if m.code then
            code_part = string.format("\n🔐 <b>提取验证码</b>：<code>%s</code> <i>(轻按直接复制)</i>", html_escape(m.code))
        end
        local content = html_escape(m.content):gsub("^%s+", ""):gsub("%s+$", "")
        local item = string.format([[📩 <b>#%d 发件人</b>：<code>%s</code>
⏰ <b>时间</b>：<code>%s</code>%s
💬 <b>内容</b>：
%s]],
            i,
            html_escape(m.sender),
            html_escape(m.timestamp),
            code_part,
            content
        )
        table.insert(items, item)
    end

    local text = string.format([[✉️ <b>5G 模组短信收件箱 (最近 %d 条)</b>

━━━━━━━━━━━━━━━━━━
%s
━━━━━━━━━━━━━━━━━━
💡 <i>单按代码块可一键复制验证码。</i>

🕰️ <i>%s</i>]],
        #list,
        table.concat(items, "\n━━━━━━━━━━━━━━━━━━\n"),
        html_escape(now)
    )

    local inline_kb = {
        {
            { text = "🔄 刷新短信", callback_data = "refresh_sms" },
            { text = "📡 模组状态", callback_data = "refresh_modem" }
        },
        {
            { text = "📇 卡内号码", callback_data = "refresh_cards" }
        }
    }

    if msg_id then
        tg.edit_msg(msg_id, text, inline_kb)
    else
        tg.send_msg(text, inline_kb)
    end
end

return M
