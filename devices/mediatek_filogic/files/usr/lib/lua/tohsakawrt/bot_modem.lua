-- TohsakaWrt Bot：模组与短信（模组状态卡、短信列表与验证码提取）
-- 共享零件来自 bot_common；本模块只放这一类功能。
local bc = require("tohsakawrt.bot_common")
local core, tg, sys, modem, clash, esim, nixio =
    bc.core, bc.tg, bc.sys, bc.modem, bc.clash, bc.esim, bc.nixio
local html_escape = bc.html_escape

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
            { text = "📈 信号趋势", callback_data = "signal_trend" }
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
